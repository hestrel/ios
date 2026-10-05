import Foundation

/// The signed-in Hestrel account. The session token lives in the Keychain, never here.
nonisolated struct Account: Codable, Equatable, Sendable {
    let id: String
    var email: String?
}

nonisolated extension Account {
    /// The Keychain slot of the session token, alongside the provider API keys.
    static let sessionTokenID = UUID(uuidString: "6F1C2A9E-5E55-4C1B-9D51-6A1E0F7B5E55")!
}

/// Progress of account and sync work, shown in Settings.
nonisolated struct SyncStatus: Equatable, Sendable {
    var isSigningIn = false
    var isDeletingAccount = false
    var isSyncing = false
    var lastSyncedAt: Date?
    var errorDescription: String?
}
