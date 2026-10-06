import AuthenticationServices
import Combine
import ComposableArchitecture
import Foundation
import UIKit

/// Signing in to a Hestrel account and keeping providers and chats in sync with it.
@Reducer
struct AccountFeature {
    @ObservableState
    struct State: Equatable {
        /// Assistant replies still streaming, which sync once they're complete.
        var streamingMessageIDs: Set<Message.ID> = []
        /// Something changed during a sync, so another one should follow it.
        var needsResync = false
        @Shared(.account) var account: Account?
        @Shared(.syncStatus) var status: SyncStatus
        @Shared(.syncLedger) var ledger: SyncLedger
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>
        @Shared(.mcpServers) var mcpServers: IdentifiedArrayOf<MCPServer>
    }

    enum Action {
        case deleteAccount
        case deleteAccountFinished(Result<Void, any Error>)
        case delegate(Delegate)
        case signIn(AppleCredential)
        case signInFinished(Result<SignInResponse, any Error>)
        case signOut
        case sync
        case syncFinished(Result<SyncReport, any Error>)
        case task

        enum Delegate: Equatable {
            case synced(SyncReport)
        }
    }

    nonisolated enum CancelID: Hashable {
        case sync
    }

    /// How long local edits settle before they're pushed, so a burst of edits is one sync.
    nonisolated static let debounce = DispatchQueue.SchedulerTimeType.Stride.seconds(3)
    /// Picks up other devices' changes while the app stays open.
    nonisolated static let pollInterval = Duration.seconds(300)

    @Dependency(\.appleSignIn) var appleSignIn
    @Dependency(\.attachments) var attachments
    @Dependency(\.continuousClock) var clock
    @Dependency(\.credentials) var credentials
    @Dependency(\.date.now) var now
    @Dependency(\.hestrelAPI) var api

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .deleteAccount:
                guard state.account != nil else { return .none }
                state.$status.withLock {
                    $0.isDeletingAccount = true
                    $0.errorDescription = nil
                }
                return .run { [api, appleSignIn, credentials] send in
                    // A fresh authorization code lets the server revoke the app's Apple tokens.
                    let credential = try await appleSignIn.authorize()
                    guard let token = credentials.secret(id: Account.sessionTokenID) else { throw HestrelAPIError.unauthorized }
                    try await api.deleteAccount(token: token, authorizationCode: credential.authorizationCode)
                    await send(.deleteAccountFinished(.success(())))
                } catch: { error, send in
                    await send(.deleteAccountFinished(.failure(error)))
                }

            case .deleteAccountFinished(.success):
                return signOutLocally(&state)

            case let .deleteAccountFinished(.failure(error)):
                state.$status.withLock { $0.isDeletingAccount = false }
                if (error as? HestrelAPIError) == .unauthorized { return signOutLocally(&state) }
                if !error.isAppleSignInCancellation {
                    state.$status.withLock { $0.errorDescription = error.localizedDescription }
                }
                return .none

            case .delegate:
                return .none

            case let .signIn(credential):
                state.$status.withLock {
                    $0.isSigningIn = true
                    $0.errorDescription = nil
                }
                return .run { [api] send in
                    let result = await Result {
                        try await api.signInWithApple(identityToken: credential.identityToken, nonce: credential.nonce)
                    }
                    await send(.signInFinished(result))
                }

            case let .signInFinished(.success(response)):
                state.$account.withLock { $0 = response.user }
                // Merge this device's data into the account as if it had never synced.
                state.$ledger.withLock { $0 = SyncLedger() }
                state.$status.withLock { $0 = SyncStatus() }
                return .run { [credentials] send in
                    credentials.setSecret(value: response.token, id: Account.sessionTokenID)
                    await send(.sync)
                }

            case let .signInFinished(.failure(error)):
                state.$status.withLock {
                    $0.isSigningIn = false
                    $0.errorDescription = error.localizedDescription
                }
                return .none

            case .signOut:
                return .merge(
                    .run { [api, credentials] _ in
                        guard let token = credentials.secret(id: Account.sessionTokenID) else { return }
                        try? await api.signOut(token: token)
                    },
                    signOutLocally(&state)
                )

            case .sync:
                guard state.account != nil else { return .none }
                guard !state.status.isSyncing else {
                    state.needsResync = true
                    return .none
                }
                state.$status.withLock { $0.isSyncing = true }
                let skipping = Set(state.streamingMessageIDs.map(SyncKey.message))
                return .run { [api, credentials, now, providers = state.$providers, conversations = state.$conversations, ledger = state.$ledger] send in
                    let result = await Result {
                        guard let token = credentials.secret(id: Account.sessionTokenID) else { throw HestrelAPIError.unauthorized }
                        let runner = SyncRunner(
                            api: api,
                            token: token,
                            providers: providers,
                            conversations: conversations,
                            ledger: ledger,
                            skipping: skipping,
                            now: now
                        )
                        return try await runner.run()
                    }
                    await send(.syncFinished(result))
                }
                .cancellable(id: CancelID.sync)

            case let .syncFinished(.success(report)):
                state.$status.withLock {
                    $0.isSyncing = false
                    $0.lastSyncedAt = now
                    $0.errorDescription = nil
                }
                let cleanup = removeLeftovers(of: report, state: &state)
                let resync: Effect<Action> = state.needsResync ? .send(.sync) : .none
                state.needsResync = false
                return .merge(
                    cleanup,
                    report == SyncReport() ? .none : .send(.delegate(.synced(report))),
                    resync
                )

            case let .syncFinished(.failure(error)):
                state.$status.withLock { $0.isSyncing = false }
                state.needsResync = false
                if (error as? HestrelAPIError) == .unauthorized {
                    let effect = signOutLocally(&state)
                    state.$status.withLock { $0.errorDescription = error.localizedDescription }
                    return effect
                }
                // Offline is normal; the next trigger retries.
                if (error as? URLError)?.code != .notConnectedToInternet {
                    state.$status.withLock { $0.errorDescription = error.localizedDescription }
                }
                return .none

            case .task:
                return .merge(
                    .send(.sync),
                    .run { [conversations = state.$conversations, providers = state.$providers] send in
                        let edits = conversations.publisher.map { _ in () }
                            .merge(with: providers.publisher.map { _ in () })
                            .debounce(for: Self.debounce, scheduler: DispatchQueue.main)
                            .values
                        for await _ in edits {
                            await send(.sync)
                        }
                    },
                    .run { send in
                        for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
                            await send(.sync)
                        }
                    },
                    .run { [clock] send in
                        for await _ in clock.timer(interval: Self.pollInterval) {
                            await send(.sync)
                        }
                    }
                )
            }
        }
    }

    /// Forgets the account on this device. Local providers and chats stay.
    private func signOutLocally(_ state: inout State) -> Effect<Action> {
        state.$account.withLock { $0 = nil }
        state.$ledger.withLock { $0 = SyncLedger() }
        state.$status.withLock { $0 = SyncStatus() }
        state.needsResync = false
        return .merge(
            .cancel(id: CancelID.sync),
            .run { [credentials] _ in credentials.setSecret(value: nil, id: Account.sessionTokenID) }
        )
    }

    /// Cleans up what another device deleted: MCP servers and keys of removed providers, and image files.
    private func removeLeftovers(of report: SyncReport, state: inout State) -> Effect<Action> {
        guard !report.removedProviderIDs.isEmpty || !report.removedAttachments.isEmpty else { return .none }
        let orphanedServers = state.mcpServers.filter { server in
            server.providerID.map(report.removedProviderIDs.contains) ?? false
        }.map(\.id)
        if !orphanedServers.isEmpty {
            state.$mcpServers.withLock { servers in orphanedServers.forEach { servers.remove(id: $0) } }
        }
        return .run { [attachments, credentials] _ in
            (report.removedProviderIDs + orphanedServers).forEach { credentials.setSecret(value: nil, id: $0) }
            attachments.delete(attachments: report.removedAttachments)
        }
    }
}

nonisolated extension Error {
    /// The user dismissed the Sign in with Apple sheet, which isn't worth an error message.
    var isAppleSignInCancellation: Bool {
        (self as? ASAuthorizationError)?.code == .canceled
    }
}
