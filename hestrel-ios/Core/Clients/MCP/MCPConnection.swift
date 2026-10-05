import Foundation

nonisolated enum MCPError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int, message: String?)
    case rpc(code: Int, message: String)
    case noResponse
    case sessionExpired
    case invalidConfig

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
        }
    }
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

    func callTool(name: String, arguments: JSONValue) async throws -> ToolResult {
        let result = try await request(
            "tools/call",
            params: .object(["name": .string(name), "arguments": arguments])
        )
        return ToolResult(
            content: Self.text(from: result),
            isError: result["isError"]?.boolValue ?? false
        )
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
        if parts.isEmpty, let structured = result["structuredContent"] {
            return structured.jsonString(pretty: true)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        try await ensureInitialized()
        do {
            return try await send(method, params: params)
        } catch MCPError.sessionExpired {
            resetSession()
            try await ensureInitialized()
            return try await send(method, params: params)
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

    private func notify(_ method: String) async throws {
        let body = RPCRequest(id: nil, method: method, params: nil)
        let (_, response) = try await session.data(for: makeRequest(body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MCPError.http(status: http.statusCode, message: nil)
        }
    }

    private func send(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextRequestID
        nextRequestID += 1

        let (bytes, response) = try await session.bytes(for: makeRequest(RPCRequest(id: id, method: method, params: params)))
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
            // The response may be preceded by notifications or server requests; wait for ours.
            for try await line in bytes.lines {
                guard let payload = ServerSentEvents.data(in: line),
                      let message = try? JSONDecoder().decode(RPCResponse.self, from: Data(payload.utf8)),
                      message.id == .number(Double(id))
                else { continue }
                return try message.unwrap()
            }
            throw MCPError.noResponse
        }

        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return try JSONDecoder().decode(RPCResponse.self, from: data).unwrap()
    }

    private func makeRequest(_ body: RPCRequest) throws -> URLRequest {
        var request = URLRequest(url: url, method: "POST", headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ], timeout: 120)
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

    func unwrap() throws -> JSONValue {
        if let error { throw MCPError.rpc(code: error.code, message: error.message) }
        return result ?? .null
    }
}
