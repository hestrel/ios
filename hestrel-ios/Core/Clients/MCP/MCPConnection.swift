import Foundation

nonisolated enum MCPError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int, message: String?)
    case rpc(code: Int, message: String)
    case noResponse
    case sessionExpired
    case invalidConfig
    /// The server no longer has the stream a dropped response was being resumed from.
    case streamLost

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "“\(url)” isn’t a valid MCP server URL."
        case let .http(status, message):
            "MCP request failed (\(status)). \(message ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        case let .rpc(_, message):
            message
        case .noResponse:
            "The MCP server closed the connection without responding."
        case .sessionExpired:
            "The MCP session expired."
        case .invalidConfig:
            "The host’s MCP configuration isn’t valid JSON with an “mcpServers” object."
        case .streamLost:
            "The reply was lost because the server restarted. Tap Try Again."
        }
    }
}

/// A message the server sends on its own while a request is in flight, such as a progress or log update.
nonisolated struct MCPNotification: Equatable, Sendable {
    let method: String
    let params: JSONValue
}

/// What a streamed response reports before its result.
nonisolated enum MCPStreamEvent: Equatable, Sendable {
    case notification(MCPNotification)
    /// The server numbers the stream's events, so it can be picked up again, even by a later app launch.
    /// `id` is the stream's ID: event IDs are `<id>:<n>`.
    case resumable(streamID: String)
}

/// A client session with one MCP server, speaking JSON-RPC over the Streamable HTTP transport.
///
/// Handles the `initialize` handshake, the `Mcp-Session-Id` header, and responses delivered
/// either as plain JSON or as a server-sent event stream.
actor MCPConnection {
    nonisolated static let protocolVersion = "2025-06-18"

    let url: URL
    let headers: [String: String]
    private let session: URLSession

    private var sessionID: String?
    private var negotiatedVersion: String?
    private var initialization: Task<Void, any Error>?
    private var nextRequestID = 1

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    // MARK: Tools

    func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let params: JSONValue? = cursor.map { .object(["cursor": .string($0)]) }
            let result = try await request("tools/list", params: params)
            for tool in result["tools"]?.arrayValue ?? [] {
                guard let name = tool["name"]?.stringValue else { continue }
                tools.append(MCPTool(
                    name: name,
                    description: tool["description"]?.stringValue ?? tool["title"]?.stringValue ?? "",
                    inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")])
                ))
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil
        return tools
    }

    /// Runs a tool. `onEvent` receives what the server reports while it works (coding agents stream their whole turn
    /// this way). If the connection drops, the call carries on from where it left off when the server supports it.
    func callTool(
        name: String,
        arguments: JSONValue,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)? = nil
    ) async throws -> ToolResult {
        let result = try await request(
            "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]),
            onEvent: onEvent
        )
        return Self.toolResult(from: result)
    }

    /// Picks up a tool call's stream after `lastEventID`, from a previous connection or app launch,
    /// and waits for its result. Stopping the task stops the call on the server.
    func resumeToolCall(lastEventID: String, onEvent: (@Sendable (MCPStreamEvent) -> Void)? = nil) async throws -> ToolResult {
        try await ensureInitialized()
        let streamID = Self.streamID(of: lastEventID)
        let result = try await withTaskCancellationHandler {
            try await resume(requestID: nil, after: lastEventID, onEvent: onEvent)
        } onCancel: {
            // This connection never sent the request, so it names the stream instead.
            Task { try? await self.notify("notifications/cancelled", params: .object(["requestId": .string(streamID)])) }
        }
        return Self.toolResult(from: result)
    }

    private static func toolResult(from result: JSONValue) -> ToolResult {
        ToolResult(content: text(from: result), isError: result["isError"]?.boolValue ?? false)
    }

    /// `<stream>:<n>` → `<stream>`.
    private static func streamID(of eventID: String) -> String {
        eventID.lastIndex(of: ":").map { String(eventID[..<$0]) } ?? eventID
    }

    /// Flattens MCP content blocks into text the model can read.
    private static func text(from result: JSONValue) -> String {
        let parts = (result["content"]?.arrayValue ?? []).compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text":
                block["text"]?.stringValue
            case "resource":
                block["resource"]?["text"]?.stringValue ?? block["resource"]?["uri"]?.stringValue
            case "resource_link":
                block["uri"]?.stringValue.map { "Resource: \($0)" }
            case let type?:
                "[\(type) content: \(block["mimeType"]?.stringValue ?? "unknown type")]"
            case nil:
                nil
            }
        }
        let text = parts.joined(separator: "\n\n")
        guard let structured = result["structuredContent"] else { return text }
        let json = structured.jsonString(pretty: true)
        if text.isEmpty { return json }
        // Structured fields the text leaves out (Codex's `threadId`, say) are what follow-up calls need.
        return text.contains(json) ? text : "\(text)\n\nStructured result:\n\(json)"
    }

    // MARK: JSON-RPC

    private func request(
        _ method: String,
        params: JSONValue?,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)? = nil
    ) async throws -> JSONValue {
        try await ensureInitialized()
        do {
            return try await send(method, params: params, onEvent: onEvent)
        } catch MCPError.sessionExpired {
            resetSession()
            try await ensureInitialized()
            return try await send(method, params: params, onEvent: onEvent)
        }
    }

    private func ensureInitialized() async throws {
        if initialization == nil {
            initialization = Task { try await performHandshake() }
        }
        do {
            try await initialization?.value
        } catch {
            initialization = nil
            throw error
        }
    }

    private func performHandshake() async throws {
        let result = try await send("initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .emptyObject,
            "clientInfo": .object([
                "name": .string("Hestrel"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"),
            ]),
        ]))
        negotiatedVersion = result["protocolVersion"]?.stringValue ?? Self.protocolVersion
        try await notify("notifications/initialized")
    }

    private func resetSession() {
        sessionID = nil
        negotiatedVersion = nil
        initialization = nil
    }

    private func notify(_ method: String, params: JSONValue? = nil) async throws {
        let body = RPCRequest(id: nil, method: method, params: params)
        let (_, response) = try await session.data(for: makeRequest(body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPError.http(status: http.statusCode, message: nil)
        }
    }

    private func send(
        _ method: String,
        params: JSONValue?,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)? = nil
    ) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1
        // Dropping the connection doesn't stop the server's work; telling it does (Codex interrupts its turn).
        return try await withTaskCancellationHandler {
            try await perform(method, id: id, params: params, onEvent: onEvent)
        } onCancel: {
            Task { try? await self.notify("notifications/cancelled", params: .object(["requestId": .number(Double(id))])) }
        }
    }

    private func perform(
        _ method: String,
        id: Int,
        params: JSONValue?,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)?
    ) async throws -> JSONValue {
        // Tool calls can be long jobs (a Codex task can run for many minutes); everything else is quick.
        let timeout: TimeInterval = method == "tools/call" ? 1_800 : 120
        let (bytes, response) = try await session.bytes(for: makeRequest(RPCRequest(id: id, method: method, params: params), timeout: timeout))
        guard let http = response as? HTTPURLResponse else { throw MCPError.noResponse }
        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }
        if http.statusCode == 404, sessionID != nil, method != "initialize" {
            throw MCPError.sessionExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes.prefix(16_000) { body.append(byte) }
            throw MCPError.http(status: http.statusCode, message: LLMError.serverMessage(from: body))
        }

        if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
            var lastEventID: String?
            do {
                if let result = try await readStream(bytes, requestID: id, lastEventID: &lastEventID, onEvent: onEvent) {
                    return result
                }
            } catch where !Task.isCancelled && lastEventID != nil {
                // The phone slept or lost its connection mid-turn; the server kept going.
            }
            guard let lastEventID else { throw MCPError.noResponse }
            return try await resume(requestID: id, after: lastEventID, onEvent: onEvent)
        }

        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return try JSONDecoder().decode(RPCResponse.self, from: data).unwrap()
    }

    /// Reads a response's server-sent events until the result for `requestID` (any result when `nil`).
    /// Returns `nil` if the stream ends first. Tracks the last event ID, to resume from.
    private func readStream(
        _ bytes: URLSession.AsyncBytes,
        requestID: Int?,
        lastEventID: inout String?,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)?
    ) async throws -> JSONValue? {
        for try await line in bytes.lines {
            if line.hasPrefix("id:") {
                let eventID = line.dropFirst(3).trimmed
                if lastEventID == nil { onEvent?(.resumable(streamID: Self.streamID(of: eventID))) }
                lastEventID = eventID
                continue
            }
            guard let payload = ServerSentEvents.data(in: line),
                  let message = try? JSONDecoder().decode(RPCResponse.self, from: Data(payload.utf8))
            else { continue }
            if message.method == nil, requestID.map({ message.id == .number(Double($0)) }) ?? (message.id != nil) {
                return try message.unwrap()
            }
            if message.id == nil, let notification = message.method {
                onEvent?(.notification(MCPNotification(method: notification, params: message.params ?? .null)))
            }
        }
        return nil
    }

    /// Reconnects to a stream after `lastEventID` (MCP's resumable streams) until its result arrives,
    /// retrying while the network or the server comes back.
    private func resume(
        requestID: Int?,
        after lastEventID: String,
        onEvent: (@Sendable (MCPStreamEvent) -> Void)?
    ) async throws -> JSONValue {
        var lastEventID: String? = lastEventID
        let giveUp = Date().addingTimeInterval(30 * 60)
        for attempt in 0... {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url, method: "GET", headers: ["Accept": "text/event-stream"], timeout: 1_800)
                for (field, value) in headers {
                    request.setValue(value, forHTTPHeaderField: field)
                }
                if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
                if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
                request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")

                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw MCPError.noResponse }
                // Servers that don't keep streams answer 404 or 405: the reply can't be recovered.
                if [404, 405].contains(http.statusCode) { throw MCPError.streamLost }
                guard (200..<300).contains(http.statusCode) else { throw MCPError.http(status: http.statusCode, message: nil) }
                if let result = try await readStream(bytes, requestID: requestID, lastEventID: &lastEventID, onEvent: onEvent) {
                    return result
                }
            } catch let error as MCPError where error == .streamLost {
                throw error
            } catch where !Task.isCancelled && Date() < giveUp {
                // Offline, or the computer is restarting its bridge: try again shortly.
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(min(1 << min(attempt, 4), 15)))
        }
        fatalError("unreachable")
    }

    private func makeRequest(_ body: RPCRequest, timeout: TimeInterval = 120) throws -> URLRequest {
        var request = URLRequest(url: url, method: "POST", headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ], timeout: timeout)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let negotiatedVersion {
            request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

private nonisolated struct RPCRequest: Encodable {
    let jsonrpc = "2.0"
    /// `nil` for notifications.
    let id: Int?
    let method: String
    let params: JSONValue?
}

private nonisolated struct RPCResponse: Decodable {
    struct RPCErrorBody: Decodable {
        let code: Int
        let message: String
    }

    let id: JSONValue?
    let result: JSONValue?
    let error: RPCErrorBody?
    /// Set on notifications, which carry `method` and `params` instead of a result.
    let method: String?
    let params: JSONValue?

    func unwrap() throws -> JSONValue {
        if let error { throw MCPError.rpc(code: error.code, message: error.message) }
        return result ?? .null
    }
}
