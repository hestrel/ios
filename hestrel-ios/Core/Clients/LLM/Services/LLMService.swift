import Foundation

/// One wire protocol for talking to a family of LLM backends.
nonisolated protocol LLMService: Sendable {
    func streamChat(_ request: ChatRequest) throws -> AsyncThrowingStream<ChatStreamEvent, any Error>
    func listModels(provider: Provider, apiKey: String?) async throws -> [ChatModel]
}

nonisolated extension ProviderKind {
    var service: any LLMService {
        switch self {
        case .openAI: ChatGPTService()
        case .gemini, .openAICompatible: OpenAIService()
        case .anthropic: AnthropicService()
        case .ollama: OllamaService()
        }
    }
}
