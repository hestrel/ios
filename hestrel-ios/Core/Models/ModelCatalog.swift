import IdentifiedCollections
import Foundation

/// Models discovered from every enabled provider, plus the loading state of each provider.
nonisolated struct ModelCatalog: Equatable, Sendable {
    private(set) var models: IdentifiedArrayOf<ChatModel> = []
    private(set) var statuses: [Provider.ID: LoadStatus] = [:]

    func models(for providerID: Provider.ID) -> [ChatModel] {
        models.filter { $0.providerID == providerID }
    }

    func selection(id: ChatModel.ID?, enabledProviderIDs: [Provider.ID]) -> ChatModel? {
        if let id {
            guard let model = models[id: id], enabledProviderIDs.contains(model.providerID) else { return nil }
            return model
        }
        return enabledProviderIDs.lazy.compactMap { providerID in
            models.first { $0.providerID == providerID }
        }.first
    }

    /// Marks the given providers as loading and forgets everything about providers not in the list.
    mutating func beginLoading(_ providerIDs: Set<Provider.ID>) {
        models.removeAll { !providerIDs.contains($0.providerID) }
        statuses = Dictionary(uniqueKeysWithValues: providerIDs.map { ($0, .loading) })
    }

    mutating func update(_ newModels: [ChatModel], for providerID: Provider.ID) {
        models.removeAll { $0.providerID == providerID }
        models.append(contentsOf: newModels)
        statuses[providerID] = .ready
    }

    mutating func fail(_ message: String, for providerID: Provider.ID) {
        models.removeAll { $0.providerID == providerID }
        statuses[providerID] = .failed(message)
    }
}
