import Foundation

/// The `/chat/completions` protocol, spoken by OpenAI, Gemini and most self-hosted servers.
nonisolated struct OpenAIService: LLMService {
    var transport = HTTPTransport()

    func streamChat(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        var messages: [WireMessage] = request.systemPrompt.map { [WireMessage(role: "system", content: .text($0))] } ?? []
        for turn in request.turns {
            messages.append(contentsOf: WireMessage.messages(for: turn))
        }
        let urlRequest = try URLRequest.post(
            Endpoint.url(request.provider.baseURL, "chat/completions"),
            body: ChatBody(
                model: request.model,
                messages: messages,
                stream: true,
                tools: request.tools.isEmpty ? nil : request.tools.map(FunctionTool.init),
                reasoningEffort: request.reasoningEffort.apiValue
            ),
            headers: headers(apiKey: request.apiKey)
        )
        return transport.stream(urlRequest, parser: Parser())
    }

    func listModels(provider: Provider, apiKey: String?) async throws -> [ChatModel] {
        let request = try URLRequest(url: Endpoint.url(provider.baseURL, "models"), headers: headers(apiKey: apiKey))
        let response = try await transport.json(ModelList.self, for: request)
        let names = response.data
            .map { String($0.id.trimmingPrefix("models/")) }
            .filter { Self.isChatModel($0, kind: provider.kind) }
        let sorted = provider.kind == .openAICompatible ? names.sorted() : names.sorted(by: >)
        return sorted.map { ChatModel(providerID: provider.id, name: $0) }
    }

    private func headers(apiKey: String?) -> [String: String] {
        guard let apiKey = apiKey?.nonBlank else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    /// `/models` on OpenAI and Gemini also lists embedding, audio and image models that can't chat.
    static func isChatModel(_ name: String, kind: ProviderKind) -> Bool {
        let name = name.lowercased()
        let nonChat = ["embedding", "tts", "audio", "realtime", "transcribe", "image", "moderation", "dall-e", "whisper", "imagen", "veo"]
        guard !nonChat.contains(where: name.contains) else { return false }
        switch kind {
        case .openAI:
            return ["gpt", "o1", "o3", "o4", "chatgpt"].contains(where: name.hasPrefix)
        case .gemini:
            return name.hasPrefix("gemini") || name.hasPrefix("gemma")
        case .anthropic, .ollama, .openAICompatible:
            return true
        }
    }
}

// MARK: - Streaming

private nonisolated struct Parser: StreamParser, Sendable {
    private struct PendingCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    /// Tool calls stream as fragments keyed by their index.
    private var pendingCalls: [Int: PendingCall] = [:]

    mutating func parse(_ line: String) throws -> StreamLine {
        guard let payload = ServerSentEvents.data(in: line) else { return .skip }
        if payload == "[DONE]" { return .final }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return .skip }
        if let message = chunk.error?.message { throw LLMError.server(message) }
        guard let delta = chunk.choices?.first?.delta else { return .skip }

        var parsed = StreamLine()
        if let reasoning = delta.reasoningContent ?? delta.reasoning, !reasoning.isEmpty {
            parsed.events.append(.reasoning(reasoning))
        }
        if let content = delta.content, !content.isEmpty {
            parsed.events.append(.text(content))
        }
        for (position, fragment) in (delta.toolCalls ?? []).enumerated() {
            let index = fragment.index ?? position
            var call = pendingCalls[index] ?? PendingCall()
            if let id = fragment.id { call.id = id }
            if let name = fragment.function?.name, !name.isEmpty { call.name = name }
            call.arguments += fragment.function?.arguments ?? ""
            pendingCalls[index] = call
        }
        return parsed
    }

    mutating func finish() -> [ChatStreamEvent] {
        defer { pendingCalls.removeAll() }
        return pendingCalls.sorted { $0.key < $1.key }.map { _, call in
            .toolCall(ToolCall(
                id: call.id.nonBlank ?? UUID().uuidString,
                name: call.name,
                arguments: call.arguments.nonBlank ?? "{}"
            ))
        }
    }
}

private nonisolated struct Chunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallFragment: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int?
                let id: String?
                let function: Function?
            }

            let content: String?
            /// DeepSeek and vLLM use `reasoning_content`; OpenRouter and LM Studio use `reasoning`.
            let reasoningContent: String?
            let reasoning: String?
            let toolCalls: [ToolCallFragment]?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }

        let delta: Delta?
    }

    struct APIError: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let error: APIError?
}

// MARK: - Request bodies

/// A tool in the `{"type": "function", ...}` shape shared by OpenAI-compatible servers and Ollama.
nonisolated struct FunctionTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    let type = "function"
    let function: Function

    init(_ tool: ToolDefinition) {
        function = Function(name: tool.name, description: tool.description, parameters: tool.inputSchema)
    }
}

private nonisolated struct WireMessage: Encodable {
    enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .text(text): try container.encode(text)
            case let .parts(parts): try container.encode(parts)
            }
        }
    }

    struct Part: Encodable {
        struct ImageURL: Encodable {
            let url: String
        }

        let type: String
        var text: String?
        var imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    struct WireToolCall: Encodable {
        struct Function: Encodable {
            let name: String
            let arguments: String
        }

        let id: String
        let type = "function"
        let function: Function
    }

    let role: String
    var content: Content?
    var toolCalls: [WireToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    /// An assistant turn that used tools expands into the assistant message plus one `tool` message per result.
    static func messages(for turn: ChatRequest.Turn) -> [WireMessage] {
        if !turn.images.isEmpty {
            let text = turn.content.nonBlank.map { [Part(type: "text", text: $0)] } ?? []
            let images = turn.images.map { Part(type: "image_url", imageURL: .init(url: $0.dataURL)) }
            return [WireMessage(role: turn.role.rawValue, content: .parts(text + images))]
        }
        guard !turn.toolCalls.isEmpty else {
            return [WireMessage(role: turn.role.rawValue, content: .text(turn.content))]
        }
        let assistant = WireMessage(
            role: "assistant",
            content: turn.content.nonBlank.map(Content.text),
            toolCalls: turn.toolCalls.map {
                WireToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
            }
        )
        let results = turn.toolCalls.map {
            WireMessage(role: "tool", content: .text($0.result?.content ?? ""), toolCallID: $0.id)
        }
        return [assistant] + results
    }
}

private nonisolated struct ChatBody: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let tools: [FunctionTool]?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, tools
        case reasoningEffort = "reasoning_effort"
    }
}

private nonisolated struct ModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}
