import Foundation

/// Anthropic's Messages API.
nonisolated struct AnthropicService: LLMService {
    var transport = HTTPTransport()

    private static let apiVersion = "2023-06-01"
    private static let mcpConnectorBeta = "mcp-client-2025-11-20"
    private static let maxTokens = 16_000

    func streamChat(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        // Every server in `mcp_servers` must be referenced by exactly one `mcp_toolset`.
        let mcpServers = request.hostedMCPServers.map(WireMCPServer.init)
        let tools = request.tools.map(WireTool.custom)
            + mcpServers.map { WireTool.mcpToolset(serverName: $0.name) }
            + (request.webSearchEnabled ? [WireTool.webSearch] : [])

        var headers = headers(apiKey: request.apiKey)
        if !mcpServers.isEmpty {
            headers["anthropic-beta"] = Self.mcpConnectorBeta
        }
        let urlRequest = try URLRequest.post(
            Endpoint.url(request.provider.baseURL, "messages"),
            body: MessagesBody(
                model: request.model,
                maxTokens: Self.maxTokens,
                system: request.systemPrompt,
                messages: request.turns.flatMap(WireMessage.messages),
                stream: true,
                tools: tools.isEmpty ? nil : tools,
                mcpServers: mcpServers.isEmpty ? nil : mcpServers,
                outputConfig: request.reasoningEffort.apiValue.map(OutputConfig.init)
            ),
            headers: headers
        )
        return transport.stream(urlRequest, parser: Parser())
    }

    func listModels(provider: Provider, apiKey: String?) async throws -> [ChatModel] {
        let request = try URLRequest(url: Endpoint.url(provider.baseURL, "models?limit=100"), headers: headers(apiKey: apiKey))
        let response = try await transport.json(ModelList.self, for: request)
        return response.data.map {
            ChatModel(providerID: provider.id, name: $0.id, displayName: $0.displayName)
        }
    }

    private func headers(apiKey: String?) -> [String: String] {
        ["x-api-key": apiKey ?? "", "anthropic-version": Self.apiVersion]
    }
}

// MARK: - Streaming

private nonisolated struct Parser: StreamParser, Sendable {
    private struct PendingCall {
        let id: String
        let name: String
        var arguments: String
        var serverName: String?
    }

    /// `tool_use` / `mcp_tool_use` blocks being streamed, keyed by content block index.
    private var pendingCalls: [Int: PendingCall] = [:]
    /// MCP calls Anthropic is running, held until their `mcp_tool_result` arrives.
    private var hostedCalls: [String: PendingCall] = [:]

    mutating func parse(_ line: String) throws -> StreamLine {
        guard let payload = ServerSentEvents.data(in: line),
              let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8))
        else { return .skip }
        let index = event.index ?? 0

        switch event.type {
        case "content_block_start":
            guard let block = event.contentBlock else { return .skip }
            switch block.type {
            case "tool_use", "mcp_tool_use", "server_tool_use":
                let input = block.input.flatMap { $0 == .emptyObject ? nil : $0.jsonString() } ?? ""
                let isWebSearch = block.type == "server_tool_use"
                pendingCalls[index] = PendingCall(
                    id: block.id ?? UUID().uuidString,
                    name: isWebSearch ? "Web search" : block.name ?? "",
                    arguments: input,
                    serverName: isWebSearch ? "Web" : block.serverName
                )
                return .skip
            case "mcp_tool_result":
                guard let callID = block.toolUseID, let call = hostedCalls.removeValue(forKey: callID) else { return .skip }
                let result = ToolResult(content: Self.text(from: block.content), isError: block.isError ?? false)
                return StreamLine(events: [.toolCall(Self.toolCall(from: call, result: result))])
            case "web_search_tool_result":
                guard let callID = block.toolUseID, let call = hostedCalls.removeValue(forKey: callID) else { return .skip }
                return StreamLine(events: [.toolCall(Self.toolCall(from: call, result: Self.searchResult(from: block.content)))])
            default:
                return .skip
            }
        case "content_block_delta":
            if let text = event.delta?.text { return StreamLine(events: [.text(text)]) }
            if let thinking = event.delta?.thinking { return StreamLine(events: [.reasoning(thinking)]) }
            if let json = event.delta?.partialJSON { pendingCalls[index]?.arguments += json }
            return .skip
        case "content_block_stop":
            guard let call = pendingCalls.removeValue(forKey: index) else { return .skip }
            if call.serverName != nil {
                hostedCalls[call.id] = call
                return .skip
            }
            let toolCall = ToolCall(id: call.id, name: call.name, arguments: call.arguments.nonBlank ?? "{}")
            return StreamLine(events: [.toolCall(toolCall)])
        case "message_stop":
            return .final
        case "error":
            throw LLMError.server(event.error?.message ?? "Anthropic returned an error.")
        default:
            return .skip
        }
    }

    mutating func finish() -> [ChatStreamEvent] {
        defer { hostedCalls.removeAll() }
        return hostedCalls.values.map {
            .toolCall(Self.toolCall(from: $0, result: ToolResult(content: "No result was returned.", isError: true)))
        }
    }

    private static func toolCall(from call: PendingCall, result: ToolResult) -> ToolCall {
        ToolCall(
            id: call.id,
            name: call.name,
            arguments: call.arguments.nonBlank ?? "{}",
            result: result,
            serverName: call.serverName,
            hostedBy: "Anthropic"
        )
    }

    /// Web search results arrive as a list of pages, or as an object with an `error_code`.
    private static func searchResult(from content: JSONValue?) -> ToolResult {
        if let code = content?["error_code"]?.stringValue {
            return ToolResult(content: "Web search failed (\(code)).", isError: true)
        }
        let pages = (content?.arrayValue ?? []).compactMap { page -> String? in
            guard let url = page["url"]?.stringValue else { return nil }
            return [page["title"]?.stringValue, url].compactMap { $0 }.joined(separator: "\n")
        }
        return ToolResult(content: pages.isEmpty ? "No results." : pages.joined(separator: "\n\n"), isError: false)
    }

    private static func text(from content: JSONValue?) -> String {
        if let text = content?.stringValue { return text }
        return (content?.arrayValue ?? [])
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n\n")
    }
}

private nonisolated struct Event: Decodable {
    struct Delta: Decodable {
        let text: String?
        let thinking: String?
        let partialJSON: String?

        enum CodingKeys: String, CodingKey {
            case text, thinking
            case partialJSON = "partial_json"
        }
    }

    struct ContentBlock: Decodable {
        let type: String
        let id: String?
        let name: String?
        let input: JSONValue?
        let serverName: String?
        let toolUseID: String?
        let isError: Bool?
        let content: JSONValue?

        enum CodingKeys: String, CodingKey {
            case type, id, name, input, content
            case serverName = "server_name"
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    struct APIError: Decodable {
        let message: String?
    }

    let type: String
    let index: Int?
    let delta: Delta?
    let contentBlock: ContentBlock?
    let error: APIError?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, error
        case contentBlock = "content_block"
    }
}

// MARK: - Request bodies

private nonisolated struct WireMessage: Encodable {
    enum Content: Encodable {
        case text(String)
        case blocks([Block])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .text(text): try container.encode(text)
            case let .blocks(blocks): try container.encode(blocks)
            }
        }
    }

    struct ImageSource: Encodable {
        let type = "base64"
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    struct Block: Encodable {
        let type: String
        var text: String?
        var source: ImageSource?
        var id: String?
        var name: String?
        var input: JSONValue?
        var toolUseID: String?
        var content: String?
        var isError: Bool?

        enum CodingKeys: String, CodingKey {
            case type, text, source, id, name, input, content
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }

    let role: String
    let content: Content

    /// An assistant turn that used tools becomes `text` + `tool_use` blocks, answered by a user turn of `tool_result` blocks.
    static func messages(for turn: ChatRequest.Turn) -> [WireMessage] {
        if !turn.images.isEmpty {
            let images = turn.images.map {
                Block(type: "image", source: ImageSource(mediaType: $0.mimeType, data: $0.base64))
            }
            let text = turn.content.nonBlank.map { [Block(type: "text", text: $0)] } ?? []
            return [WireMessage(role: turn.role.rawValue, content: .blocks(images + text))]
        }
        guard !turn.toolCalls.isEmpty else {
            return [WireMessage(role: turn.role.rawValue, content: .text(turn.content))]
        }
        var blocks: [Block] = turn.content.nonBlank.map { [Block(type: "text", text: $0)] } ?? []
        blocks += turn.toolCalls.map {
            Block(type: "tool_use", id: $0.id, name: $0.name, input: JSONValue(json: $0.arguments) ?? .emptyObject)
        }
        let results = turn.toolCalls.map {
            Block(type: "tool_result", toolUseID: $0.id, content: $0.result?.content ?? "", isError: $0.result?.isError)
        }
        return [
            WireMessage(role: "assistant", content: .blocks(blocks)),
            WireMessage(role: "user", content: .blocks(results)),
        ]
    }
}

private nonisolated enum WireTool: Encodable {
    case custom(ToolDefinition)
    case mcpToolset(serverName: String)
    /// Anthropic's server-side web search. The basic version works across current and older models.
    case webSearch

    private enum CodingKeys: String, CodingKey {
        case type, name, description
        case inputSchema = "input_schema"
        case mcpServerName = "mcp_server_name"
        case maxUses = "max_uses"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .custom(tool):
            try container.encode(tool.name, forKey: .name)
            try container.encode(tool.description, forKey: .description)
            try container.encode(tool.inputSchema, forKey: .inputSchema)
        case let .mcpToolset(serverName):
            try container.encode("mcp_toolset", forKey: .type)
            try container.encode(serverName, forKey: .mcpServerName)
        case .webSearch:
            try container.encode("web_search_20250305", forKey: .type)
            try container.encode("web_search", forKey: .name)
            try container.encode(5, forKey: .maxUses)
        }
    }
}

private nonisolated struct WireMCPServer: Encodable {
    let type = "url"
    let url: String
    let name: String
    let authorizationToken: String?

    enum CodingKeys: String, CodingKey {
        case type, url, name
        case authorizationToken = "authorization_token"
    }

    init(_ server: HostedMCPServer) {
        url = server.url
        name = server.name
        authorizationToken = server.bearerToken
    }
}

private nonisolated struct OutputConfig: Encodable {
    let effort: String
}

private nonisolated struct MessagesBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [WireMessage]
    let stream: Bool
    let tools: [WireTool]?
    let mcpServers: [WireMCPServer]?
    let outputConfig: OutputConfig?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, tools
        case maxTokens = "max_tokens"
        case mcpServers = "mcp_servers"
        case outputConfig = "output_config"
    }
}

private nonisolated struct ModelList: Decodable {
    struct Model: Decodable {
        let id: String
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    let data: [Model]
}
