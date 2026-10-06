import ComposableArchitecture
import Foundation

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Conversation>>.Default {
    static var conversations: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "conversations.json")), default: []]
    }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<Provider>>.Default {
    static var providers: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "providers.json")), default: Provider.presets]
    }
}

extension SharedKey where Self == InMemoryKey<ModelCatalog>.Default {
    static var modelCatalog: Self {
        Self[.inMemory("modelCatalog"), default: ModelCatalog()]
    }
}

extension SharedKey where Self == AppStorageKey<String?> {
    static var selectedModelID: Self {
        appStorage("selectedModelID")
    }
}

extension SharedKey where Self == AppStorageKey<String>.Default {
    static var systemPrompt: Self {
        Self[.appStorage("systemPrompt"), default: ""]
    }
}

extension SharedKey where Self == FileStorageKey<IdentifiedArrayOf<MCPServer>>.Default {
    static var mcpServers: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "mcp-servers.json")), default: []]
    }
}

extension SharedKey where Self == InMemoryKey<ToolCatalog>.Default {
    static var toolCatalog: Self {
        Self[.inMemory("toolCatalog"), default: ToolCatalog()]
    }
}

extension SharedKey where Self == FileStorageKey<Account?>.Default {
    static var account: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "account.json")), default: nil]
    }
}

extension SharedKey where Self == FileStorageKey<SyncLedger>.Default {
    static var syncLedger: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "sync-ledger.json")), default: SyncLedger()]
    }
}

extension SharedKey where Self == InMemoryKey<SyncStatus>.Default {
    static var syncStatus: Self {
        Self[.inMemory("syncStatus"), default: SyncStatus()]
    }
}

nonisolated extension SharedKey where Self == FileStorageKey<GoogleConnection>.Default {
    static var googleConnection: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "google-connection.json")), default: GoogleConnection()]
    }
}

extension SharedKey where Self == AppStorageKey<ReasoningEffort>.Default {
    static var reasoningEffort: Self {
        Self[.appStorage("reasoningEffort"), default: .auto]
    }
}

extension SharedKey where Self == AppStorageKey<Bool>.Default {
    /// The Web Search plugin, which applies to every provider.
    static var webSearchEnabled: Self {
        Self[.appStorage("webSearchEnabled"), default: true]
    }
}

nonisolated extension SharedKey where Self == FileStorageKey<CodeDefaults>.Default {
    static var codeDefaults: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "code-defaults.json")), default: CodeDefaults()]
    }
}

extension SharedKey where Self == InMemoryKey<IdentifiedArrayOf<Computer>>.Default {
    /// Computers paired with the account, with their online status, as last fetched.
    static var computers: Self {
        Self[.inMemory("computers"), default: []]
    }
}
