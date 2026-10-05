import ComposableArchitecture
import Foundation

/// One sync pass: pull everything new, then push local edits.
///
/// Pulling first means a device that has never synced adopts the account's data before
/// pushing its own, instead of overwriting it with defaults.
nonisolated struct SyncRunner: Sendable {
    let api: HestrelAPIClient
    let token: String
    let providers: Shared<IdentifiedArrayOf<Provider>>
    let conversations: Shared<IdentifiedArrayOf<Conversation>>
    let ledger: Shared<SyncLedger>
    /// Objects still being edited, such as a reply that is streaming in.
    let skipping: Set<SyncKey>
    let now: Date

    @concurrent
    func run() async throws -> SyncReport {
        var report = SyncReport()

        var records: [SyncRecord] = []
        var cursor = ledger.wrappedValue.cursor
        var hasMore = true
        while hasMore {
            let page = try await api.pull(token: token, cursor: cursor)
            records += page.records
            cursor = page.cursor
            hasMore = page.hasMore
        }
        await apply(records, force: false, cursor: cursor, into: &report)

        // Encoding every object is the expensive part, so it happens off the main actor.
        let local = try SyncEngine.localRecords(providers: providers.wrappedValue, conversations: conversations.wrappedValue)
        let changes = try SyncEngine.pendingChanges(local: local, ledger: ledger.wrappedValue, skipping: skipping, now: now)
        for batch in SyncEngine.batches(changes, local: local) {
            let response = try await api.push(token: token, changes: batch)
            await MainActor.run {
                ledger.withLock { SyncEngine.markAccepted(response.accepted, pushed: batch, local: local, ledger: &$0) }
            }
            await apply(response.conflicts, force: true, cursor: nil, into: &report)
        }
        return report
    }

    /// Merges records on the main actor, where every other edit to this state happens,
    /// and writes back only what actually changed.
    @MainActor
    private func apply(_ records: [SyncRecord], force: Bool, cursor: Int?, into report: inout SyncReport) {
        var providers = providers.wrappedValue
        var conversations = conversations.wrappedValue
        var ledger = ledger.wrappedValue
        if !records.isEmpty {
            SyncEngine.apply(
                records,
                providers: &providers,
                conversations: &conversations,
                ledger: &ledger,
                force: force,
                report: &report
            )
        }
        if let cursor { ledger.cursor = cursor }

        if providers != self.providers.wrappedValue { self.providers.withLock { $0 = providers } }
        if conversations != self.conversations.wrappedValue { self.conversations.withLock { $0 = conversations } }
        if ledger != self.ledger.wrappedValue { self.ledger.withLock { $0 = ledger } }
    }
}
