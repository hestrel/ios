import Foundation

/// A model offered by a provider, e.g. `gpt-5` on OpenAI or `llama3.2` on Ollama.
nonisolated struct ChatModel: Equatable, Hashable, Identifiable, Sendable {
    let providerID: Provider.ID
    /// The identifier sent to the provider's API.
    let name: String
    let displayName: String

    init(providerID: Provider.ID, name: String, displayName: String? = nil) {
        self.providerID = providerID
        self.name = name
        self.displayName = displayName ?? name
    }

    var id: String { "\(providerID.uuidString)/\(name)" }
}
