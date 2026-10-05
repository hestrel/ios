import CryptoKit
import Foundation
import IdentifiedCollections

/// A conversation as synced: everything but its messages, which sync as records of their own.
nonisolated struct ConversationRecord: Codable, Equatable, Sendable {
    let id: UUID
    var kind: Conversation.Kind
    var title: String
    var modelID: ChatModel.ID?
    let createdAt: Date
    var updatedAt: Date

    init(_ conversation: Conversation) {
        id = conversation.id
        kind = conversation.kind
        title = conversation.title
        modelID = conversation.modelID
        createdAt = conversation.createdAt
        updatedAt = conversation.updatedAt
    }
}

/// A local object encoded the way it's synced.
nonisolated struct LocalRecord: Sendable {
    let key: SyncKey
    let parentID: String?
    let data: Data
    let fingerprint: String
}

/// What a sync changed locally, for the app to react to.
nonisolated struct SyncReport: Equatable, Sendable {
    var removedConversationIDs: [Conversation.ID] = []
    var removedProviderIDs: [Provider.ID] = []
    var removedAttachments: [Attachment] = []
    var providersChanged = false
}

/// The pure part of sync: diffing local state against the ledger and merging server records.
///
/// Rules, matching the server: last writer wins, deletions are final, and a device that has never
/// synced an object defers to the server's copy (so a new device adopts the account's providers
/// instead of overwriting them with its defaults).
nonisolated enum SyncEngine {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Keeps each push comfortably under the server's 200 changes and 1 MB.
    static let maxBatchCount = 150
    static let maxBatchBytes = 700_000

    // MARK: Encoding

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func record(_ key: SyncKey, parentID: String? = nil, value: some Encodable) throws -> LocalRecord {
        let data = try encoder.encode(value)
        return LocalRecord(key: key, parentID: parentID, data: data, fingerprint: fingerprint(data))
    }

    /// Every provider, conversation and message, keyed by `SyncKey.rawValue`.
    static func localRecords(
        providers: IdentifiedArrayOf<Provider>,
        conversations: IdentifiedArrayOf<Conversation>
    ) throws -> [String: LocalRecord] {
        var records: [String: LocalRecord] = [:]
        func add(_ record: LocalRecord) { records[record.key.rawValue] = record }

        for provider in providers {
            try add(record(.provider(provider.id), value: provider))
        }
        for conversation in conversations {
            try add(record(.conversation(conversation.id), value: ConversationRecord(conversation)))
            for message in conversation.messages {
                try add(record(.message(message.id), parentID: conversation.id.uuidString, value: message))
            }
        }
        return records
    }

    // MARK: Push

    /// Local objects that changed since they last synced, and tombstones for ones that are gone.
    static func pendingChanges(
        local: [String: LocalRecord],
        ledger: SyncLedger,
        skipping: Set<SyncKey>,
        now: Date
    ) throws -> [SyncChange] {
        let updatedAt = Int64(now.timeIntervalSince1970 * 1000)
        var changes: [SyncChange] = []

        for record in local.values where !skipping.contains(record.key) {
            guard ledger.entries[record.key.rawValue]?.fingerprint != record.fingerprint else { continue }
            changes.append(SyncChange(
                collection: record.key.collection,
                id: record.key.id,
                parentId: record.parentID,
                data: try JSONDecoder().decode(JSONValue.self, from: record.data),
                deleted: false,
                updatedAt: updatedAt
            ))
        }

        for (rawKey, entry) in ledger.entries where local[rawKey] == nil {
            guard let key = SyncKey(rawValue: rawKey), !skipping.contains(key) else { continue }
            // The server deletes a conversation's messages along with it.
            if key.collection == .message, let parentID = entry.parentID,
               ledger.entries[SyncKey.conversation(parentID).rawValue] != nil,
               local[SyncKey.conversation(parentID).rawValue] == nil
            {
                continue
            }
            changes.append(SyncChange(
                collection: key.collection,
                id: key.id,
                parentId: entry.parentID,
                data: nil,
                deleted: true,
                updatedAt: updatedAt
            ))
        }

        // Parents first, so a conversation exists on the server before its messages.
        return changes.sorted { ($0.collection.order, $0.id) < ($1.collection.order, $1.id) }
    }

    /// Splits changes into pushes the server accepts. A single change too big to ever fit is dropped.
    static func batches(_ changes: [SyncChange], local: [String: LocalRecord]) -> [[SyncChange]] {
        var batches: [[SyncChange]] = []
        var current: [SyncChange] = []
        var currentBytes = 0
        for change in changes {
            let bytes = (local[change.key.rawValue]?.data.count ?? 0) + 200
            guard bytes <= maxBatchBytes else { continue }
            if current.count == maxBatchCount || currentBytes + bytes > maxBatchBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(change)
            currentBytes += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Records the server accepted, so they stop counting as local edits.
    static func markAccepted(
        _ accepted: [PushResponse.Accepted],
        pushed: [SyncChange],
        local: [String: LocalRecord],
        ledger: inout SyncLedger
    ) {
        let pushedByKey = Dictionary(pushed.map { ($0.key.rawValue, $0) }, uniquingKeysWith: { $1 })
        for item in accepted {
            let rawKey = SyncKey(collection: item.collection, id: item.id).rawValue
            guard let change = pushedByKey[rawKey] else { continue }
            if change.deleted {
                ledger.entries[rawKey] = nil
                if change.collection == .conversation {
                    ledger.entries = ledger.entries.filter { $0.value.parentID != change.id }
                }
            } else if let record = local[rawKey] {
                ledger.entries[rawKey] = .init(fingerprint: record.fingerprint, parentID: record.parentID)
            }
        }
    }

    // MARK: Pull

    /// Merges server records into local state.
    ///
    /// - Parameter force: Apply even over unsynced local edits. Used for the winning copies the
    ///   server returns when it rejects a push.
    static func apply(
        _ records: [SyncRecord],
        providers: inout IdentifiedArrayOf<Provider>,
        conversations: inout IdentifiedArrayOf<Conversation>,
        ledger: inout SyncLedger,
        force: Bool,
        report: inout SyncReport
    ) {
        for record in records.sorted(by: { $0.collection.order < $1.collection.order }) {
            guard let id = UUID(uuidString: record.id) else { continue }
            let rawKey = record.key.rawValue

            if record.deleted {
                remove(record, id: id, providers: &providers, conversations: &conversations, ledger: &ledger, report: &report)
                continue
            }

            let localFingerprint = currentFingerprint(record, id: id, providers: providers, conversations: conversations)
            // Edited or deleted here since the last sync: the pending push wins.
            if !force, let entry = ledger.entries[rawKey], entry.fingerprint != localFingerprint { continue }

            do {
                guard let data = record.data else { continue }
                let encoded = try encoder.encode(data)
                switch record.collection {
                case .provider:
                    let provider = try decoder.decode(Provider.self, from: encoded)
                    let synced = try self.record(record.key, value: provider)
                    if synced.fingerprint != localFingerprint {
                        providers[id: id] = provider
                        report.providersChanged = true
                    }
                    ledger.entries[rawKey] = .init(fingerprint: synced.fingerprint)

                case .conversation:
                    let remote = try decoder.decode(ConversationRecord.self, from: encoded)
                    let synced = try self.record(record.key, value: remote)
                    if synced.fingerprint != localFingerprint {
                        upsert(remote, into: &conversations)
                    }
                    ledger.entries[rawKey] = .init(fingerprint: synced.fingerprint)

                case .message:
                    guard let parentID = record.parentId.flatMap(UUID.init(uuidString:)) else { continue }
                    let message = try decoder.decode(Message.self, from: encoded)
                    let synced = try self.record(record.key, parentID: parentID.uuidString, value: message)
                    if conversations[id: parentID] == nil {
                        // Deleted here and about to be deleted on the server too.
                        if ledger.entries[SyncKey.conversation(parentID).rawValue] != nil { continue }
                        // Its conversation hasn't arrived yet; a placeholder holds the message until it does.
                        let placeholder = Conversation(id: parentID, title: "Untitled", createdAt: message.createdAt)
                        conversations.append(placeholder)
                        ledger.entries[SyncKey.conversation(parentID).rawValue] = .init(
                            fingerprint: try self.record(.conversation(parentID), value: ConversationRecord(placeholder)).fingerprint
                        )
                    }
                    if synced.fingerprint != localFingerprint {
                        upsert(message, into: &conversations[id: parentID]!.messages)
                    }
                    ledger.entries[rawKey] = .init(fingerprint: synced.fingerprint, parentID: parentID.uuidString)
                }
            } catch {
                // A record this version of the app can't read is skipped, not fatal.
                continue
            }
        }
    }

    private static func remove(
        _ record: SyncRecord,
        id: UUID,
        providers: inout IdentifiedArrayOf<Provider>,
        conversations: inout IdentifiedArrayOf<Conversation>,
        ledger: inout SyncLedger,
        report: inout SyncReport
    ) {
        ledger.entries[record.key.rawValue] = nil
        switch record.collection {
        case .provider:
            if providers.remove(id: id) != nil {
                report.removedProviderIDs.append(id)
                report.providersChanged = true
            }
        case .conversation:
            if let conversation = conversations.remove(id: id) {
                report.removedConversationIDs.append(id)
                report.removedAttachments += conversation.messages.flatMap(\.attachments)
            }
            ledger.entries = ledger.entries.filter { $0.value.parentID != record.id }
        case .message:
            let parentID = record.parentId.flatMap(UUID.init(uuidString:))
                ?? conversations.first(where: { $0.messages[id: id] != nil })?.id
            guard let parentID, let message = conversations[id: parentID]?.messages.remove(id: id) else { return }
            report.removedAttachments += message.attachments
        }
    }

    private static func currentFingerprint(
        _ record: SyncRecord,
        id: UUID,
        providers: IdentifiedArrayOf<Provider>,
        conversations: IdentifiedArrayOf<Conversation>
    ) -> String? {
        switch record.collection {
        case .provider:
            providers[id: id].flatMap { try? self.record(record.key, value: $0).fingerprint }
        case .conversation:
            conversations[id: id].flatMap { try? self.record(record.key, value: ConversationRecord($0)).fingerprint }
        case .message:
            record.parentId.flatMap(UUID.init(uuidString:))
                .flatMap { conversations[id: $0]?.messages[id: id] }
                .flatMap { try? self.record(record.key, value: $0).fingerprint }
        }
    }

    private static func upsert(_ remote: ConversationRecord, into conversations: inout IdentifiedArrayOf<Conversation>) {
        if conversations[id: remote.id] == nil {
            conversations.append(Conversation(id: remote.id, kind: remote.kind, title: remote.title, createdAt: remote.createdAt))
        }
        conversations[id: remote.id]?.kind = remote.kind
        conversations[id: remote.id]?.title = remote.title
        conversations[id: remote.id]?.modelID = remote.modelID
        conversations[id: remote.id]?.updatedAt = remote.updatedAt
    }

    /// Replaces a message in place, or inserts a new one in chronological order.
    private static func upsert(_ message: Message, into messages: inout IdentifiedArrayOf<Message>) {
        if messages[id: message.id] != nil {
            messages[id: message.id] = message
        } else {
            let index = messages.firstIndex { $0.createdAt > message.createdAt } ?? messages.endIndex
            messages.insert(message, at: index)
        }
    }
}

nonisolated extension SyncKey {
    static func provider(_ id: UUID) -> Self { Self(collection: .provider, id: id.uuidString) }
    static func conversation(_ id: UUID) -> Self { Self(collection: .conversation, id: id.uuidString) }
    static func conversation(_ id: String) -> Self { Self(collection: .conversation, id: id) }
    static func message(_ id: UUID) -> Self { Self(collection: .message, id: id.uuidString) }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let collection = SyncCollection(rawValue: String(parts[0])) else { return nil }
        self.init(collection: collection, id: String(parts[1]))
    }
}

nonisolated extension SyncCollection {
    /// Parents sort before children.
    var order: Int {
        switch self {
        case .provider: 0
        case .conversation: 1
        case .message: 2
        }
    }
}
