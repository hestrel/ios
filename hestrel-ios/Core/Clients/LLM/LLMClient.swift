import ComposableArchitecture
import Foundation

@DependencyClient
nonisolated struct LLMClient: Sendable {
    var streamChat: @Sendable (_ request: ChatRequest) -> AsyncThrowingStream<ChatStreamEvent, any Error> = { _ in .finished() }
    var listModels: @Sendable (_ provider: Provider, _ apiKey: String?) async throws -> [ChatModel]
}

nonisolated extension LLMClient: DependencyKey {
    static let liveValue = LLMClient(
        streamChat: { request in
            do {
                if request.provider.kind.requiresAPIKey, request.apiKey?.nonBlank == nil {
                    throw LLMError.missingAPIKey(provider: request.provider.name)
                }
                return try request.provider.kind.service.streamChat(request)
            } catch {
                return AsyncThrowingStream { $0.finish(throwing: error) }
            }
        },
        listModels: { provider, apiKey in
            if provider.kind.requiresAPIKey, apiKey?.nonBlank == nil {
                throw LLMError.missingAPIKey(provider: provider.name)
            }
            return try await provider.kind.service.listModels(provider: provider, apiKey: apiKey)
        }
    )

    static let previewValue = LLMClient(
        streamChat: { _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    for word in sampleResponse.split(separator: " ", omittingEmptySubsequences: false) {
                        try await Task.sleep(for: .milliseconds(25))
                        continuation.yield(.text(word + " "))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        },
        listModels: { provider, _ in
            [
                ChatModel(providerID: provider.id, name: "preview-large", displayName: "Preview Large"),
                ChatModel(providerID: provider.id, name: "preview-small", displayName: "Preview Small"),
            ]
        }
    )

    static let testValue = LLMClient()

    private static let sampleResponse = """
    Here's a quick overview of **The Composable Architecture**:

    1. **State** describes everything a feature needs to render.
    2. **Actions** describe every event that can happen.
    3. **Reducers** evolve state and return *effects*.

    ```swift
    @Reducer
    struct Counter {
        @ObservableState
        struct State { var count = 0 }
    }
    ```

    Let me know if you'd like to dive deeper!
    """
}

nonisolated extension DependencyValues {
    var llm: LLMClient {
        get { self[LLMClient.self] }
        set { self[LLMClient.self] = newValue }
    }
}
