import Foundation

/// Ollama's native API, streamed as newline-delimited JSON.
nonisolated struct OllamaService: LLMService {
    var transport = HTTPTransport()

    func streamChat(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        var messages: [WireMessage] = request.systemPrompt.map { [WireMessage(role: "system", content: $0)] } ?? []
        for turn in request.turns {
            messages.append(contentsOf: WireMessage.messages(for: turn))
        }
        // Cold-loading a large model can take minutes before the first token arrives.
        let urlRequest = try URLRequest.post(
            Endpoint.url(request.provider.baseURL, "api/chat"),
            body: ChatBody(
                model: request.model,
                messages: messages,
                stream: true,
                tools: request.tools.isEmpty ? nil : request.tools.map(FunctionTool.init)
            ),
            headers: headers(apiKey: request.apiKey),
            timeout: 600
        )
        return transport.stream(urlRequest, parser: Parser())
    }

    func listModels(provider: Provider, apiKey: String?) async throws -> [ChatModel] {
        let request = try URLRequest(url: Endpoint.url(provider.baseURL, "api/tags"), headers: headers(apiKey: apiKey), timeout: 10)
        let response = try await transport.json(TagList.self, for: request)
        return response.models
            .map(\.name)
            .sorted()
            .map { ChatModel(providerID: provider.id, name: $0) }
    }

    /// Plain Ollama needs no key, but servers behind a proxy or ollama.com do.
    private func headers(apiKey: String?) -> [String: String] {
        guard let apiKey = apiKey?.nonBlank else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }
}

// MARK: - Streaming

private nonisolated struct Parser: StreamParser, Sendable {
    mutating func parse(_ line: String) throws -> StreamLine {
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { return .skip }
        if let error = chunk.error { throw LLMError.server(error) }

        var parsed = StreamLine(isFinal: chunk.done ?? false)
        if let thinking = chunk.message?.thinking, !thinking.isEmpty {
            parsed.events.append(.reasoning(thinking))
        }
        if let content = chunk.message?.content, !content.isEmpty {
            parsed.events.append(.text(content))
        }
        // Ollama sends each tool call whole, and without an ID.
        for call in chunk.message?.toolCalls ?? [] {
            parsed.events.append(.toolCall(ToolCall(
                id: UUID().uuidString,
                name: call.function.name,
                arguments: (call.function.arguments ?? .emptyObject).jsonString()
            )))
        }
        return parsed
    }
}

private nonisolated struct Chunk: Decodable {
    struct ChunkMessage: Decodable {
        let content: String?
        let thinking: String?
        let toolCalls: [WireToolCall]?

        enum CodingKeys: String, CodingKey {
            case content, thinking
            case toolCalls = "tool_calls"
        }
    }

    let message: ChunkMessage?
    let done: Bool?
    let error: String?
}

// MARK: - Request bodies

private nonisolated struct WireToolCall: Codable {
    struct Function: Codable {
        let name: String
        let arguments: JSONValue?
    }

    let function: Function
}

private nonisolated struct WireMessage: Encodable {
    let role: String
    var content: String
    /// Base64-encoded images, for vision models.
    var images: [String]?
    var toolCalls: [WireToolCall]?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content, images
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    /// An assistant turn that used tools expands into the assistant message plus one `tool` message per result.
    static func messages(for turn: ChatRequest.Turn) -> [WireMessage] {
        guard !turn.toolCalls.isEmpty else {
            let images = turn.images.isEmpty ? nil : turn.images.map(\.base64)
            return [WireMessage(role: turn.role.rawValue, content: turn.content, images: images)]
        }
        let assistant = WireMessage(
            role: "assistant",
            content: turn.content,
            toolCalls: turn.toolCalls.map {
                WireToolCall(function: .init(name: $0.name, arguments: JSONValue(json: $0.arguments) ?? .emptyObject))
            }
        )
        let results = turn.toolCalls.map {
            WireMessage(role: "tool", content: $0.result?.content ?? "", toolName: $0.name)
        }
        return [assistant] + results
    }
}

private nonisolated struct ChatBody: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let tools: [FunctionTool]?
}

private nonisolated struct TagList: Decodable {
    struct Model: Decodable {
        let name: String
    }

    let models: [Model]
}
