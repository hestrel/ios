import ComposableArchitecture
import Foundation
import OpenAI

/// Responses through the Swift SDK, authorized with a short-lived ChatGPT OAuth token.
nonisolated struct ChatGPTService: LLMService {
    @Dependency(\.chatGPT) var chatGPT

    func streamChat(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let query = try Self.query(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let token = try await chatGPT.accessToken(request.provider.id)
                    let client = OpenAI(configuration: .init(token: token), middlewares: [ChatGPTSearchStreamMiddleware()])
                    var completed = false
                    var finishedText = ""
                    for try await event in client.responses.createResponseStreaming(query: query) {
                        try Task.checkCancellation()
                        switch event {
                        case let .outputText(.delta(delta)):
                            continuation.yield(.text(delta.delta))
                        case let .reasoningSummaryText(.delta(delta)):
                            continuation.yield(.reasoning(delta.delta))
                        case let .webSearchCall(.inProgress(event)):
                            continuation.yield(.toolCall(ChatGPTStreamOutput.searchActivity(id: event.itemId)))
                        case let .outputItem(.done(event)):
                            if let text = ChatGPTStreamOutput.citedText(event.item) {
                                finishedText += text
                                continuation.yield(.textReplaced(finishedText))
                            }
                            if let call = ChatGPTStreamOutput.toolCall(event.item) {
                                continuation.yield(.toolCall(call))
                            }
                        case .completed: completed = true
                        case .incomplete:
                            throw ChatGPTError.message("ChatGPT could not finish the response. Please try again.")
                        case let .failed(event):
                            throw ChatGPTError.message(event.response.error?.message ?? "ChatGPT could not complete the request. Check your plan usage in provider settings.")
                        case let .error(event): throw ChatGPTError.message(event.message)
                        default: break
                        }
                    }
                    guard completed else { throw ChatGPTError.message("The ChatGPT connection ended before the response completed. Please try again.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels(provider: Provider, apiKey: String?) async throws -> [ChatModel] {
        // ChatGPT's account-specific catalog differs from the SDK's API-key model-list schema.
        struct Catalog: Decodable {
            struct Model: Decodable { var slug: String; var display_name: String; var visibility: String }
            var models: [Model]
        }
        let token = try await chatGPT.accessToken(provider.id)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let catalog = try await HTTPTransport().json(Catalog.self, for: request)
        return catalog.models.filter { $0.visibility == "list" }.map {
            ChatModel(providerID: provider.id, name: $0.slug, displayName: $0.display_name)
        }
    }

    static func query(_ request: ChatRequest) throws -> CreateModelResponseQuery {
        func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
        }
        var input: [InputItem] = []
        for turn in request.turns {
            if turn.role == .user {
                var content: [[String: Any]] = []
                if !turn.content.isEmpty { content.append(["type": "input_text", "text": turn.content]) }
                content += turn.images.map { ["type": "input_image", "image_url": $0.dataURL, "detail": "auto"] }
                if !content.isEmpty {
                    input.append(.inputMessage(try decode(EasyInputMessage.self,
                        ["role": "user", "type": "message", "content": content])))
                }
            } else if !turn.content.isEmpty {
                input.append(.inputMessage(.init(role: .assistant, content: .textInput(turn.content))))
            }
            for call in turn.toolCalls {
                input.append(.item(try decode(Components.Schemas.Item.self,
                    ["type": "function_call", "call_id": call.id, "name": call.name,
                     "namespace": "hestrel", "arguments": call.arguments])))
                input.append(.item(try decode(Components.Schemas.Item.self,
                    ["type": "function_call_output", "call_id": call.id, "output": call.result?.content ?? ""])))
            }
        }
        var tools: [Tool] = request.webSearchEnabled ? [ChatGPTStreamOutput.webSearchTool] : []
        if !request.tools.isEmpty {
            let functions: [[String: Any]] = try request.tools.map { tool in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)), "strict": false]
            }
            tools.append(try decode(Tool.self, ["type": "namespace", "name": "hestrel",
                "description": "Tools available on this device.", "tools": functions]))
        }
        let effort = request.reasoningEffort.apiValue.flatMap(Components.Schemas.ReasoningEffort.init(rawValue:))
        return CreateModelResponseQuery(input: .inputItemList(input), model: request.model,
                                        instructions: request.systemPrompt,
                                        reasoning: effort.map { .init(effort: $0) },
                                        store: false, stream: true,
                                        tools: tools.isEmpty ? nil : tools)
    }
}
