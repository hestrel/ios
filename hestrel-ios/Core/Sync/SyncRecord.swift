import Foundation

nonisolated enum SyncCollection: String, Codable, Sendable {
    case provider
    case conversation
    case message
}

/// Identifies a synced object, e.g. `conversation/6F1C…`.
nonisolated struct SyncKey: Hashable, Sendable {
    let collection: SyncCollection
    let id: String

    var rawValue: String { "\(collection.rawValue)/\(id)" }
}

/// A record as the server returns it from a pull, or as the winning copy of a conflict.
nonisolated struct SyncRecord: Decodable, Sendable {
    let collection: SyncCollection
    let id: String
    let parentId: String?
    let data: JSONValue?
    let deleted: Bool
    let updatedAt: Int64
    let seq: Int?

    var key: SyncKey { SyncKey(collection: collection, id: id) }
}

/// A local edit or deletion sent in a push.
nonisolated struct SyncChange: Encodable, Sendable {
    let collection: SyncCollection
    let id: String
    let parentId: String?
    let data: JSONValue?
    let deleted: Bool
    let updatedAt: Int64

    var key: SyncKey { SyncKey(collection: collection, id: id) }
}

nonisolated struct PushResponse: Decodable, Sendable {
    struct Accepted: Decodable, Sendable {
        let collection: SyncCollection
        let id: String
        let seq: Int
    }

    let accepted: [Accepted]
    let conflicts: [SyncRecord]
}

nonisolated struct PullResponse: Decodable, Sendable {
    let records: [SyncRecord]
    let cursor: Int
    let hasMore: Bool
}

/// What this device last exchanged with the server.
///
/// Local edits are found by comparing each object's current fingerprint with the one recorded
/// here, so features can keep mutating `@Shared` state without knowing about sync.
nonisolated struct SyncLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// SHA-256 of the object's encoding when it was last pushed or pulled.
        var fingerprint: String
        /// The owning conversation of a message, needed to delete it later.
        var parentID: String?
    }

    /// The highest server `seq` this device has pulled.
    var cursor = 0
    /// Keyed by `SyncKey.rawValue`.
    var entries: [String: Entry] = [:]
}
