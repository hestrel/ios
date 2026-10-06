import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
    nonisolated enum Page: Hashable, Sendable {
        case account, providers, instructions, data, about

        var title: String {
            switch self {
            case .account: "Account"
            case .providers: "Providers"
            case .instructions: "Custom Instructions"
            case .data: "Data"
            case .about: "About"
            }
        }
    }

    @Reducer
    enum Destination {
        case alert(AlertState<SettingsFeature.Action.Alert>)
        case providerEditor(ProviderEditorFeature)
    }

    @ObservableState
    struct State: Equatable {
        var path: [Page] = []
        @Presents var destination: Destination.State?
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.modelCatalog) var catalog: ModelCatalog
        @Shared(.systemPrompt) var systemPrompt: String
        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>
        @Shared(.mcpServers) var mcpServers: IdentifiedArrayOf<MCPServer>
        @Shared(.account) var account: Account?
        @Shared(.syncStatus) var syncStatus: SyncStatus
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case openPluginsTapped
        case addProviderTapped(ProviderKind)
        case deleteAccountTapped
        case deleteAllChatsTapped
        case delegate(Delegate)
        case destination(PresentationAction<Destination.Action>)
        case doneTapped
        case providerDeleted(Provider.ID)
        case providerTapped(Provider.ID)
        case signInWithAppleCompleted(AppleCredential)
        case signInWithAppleFailed(String)
        case signOutTapped
        case syncNowTapped

        enum Alert: Equatable {
            case confirmDeleteAccount
            case confirmDeleteAllChats
            case confirmSignOut
        }

        enum Delegate: Equatable {
            case openPlugins
            case allChatsDeleted
            case configurationChanged
            case deleteAccount
            case signIn(AppleCredential)
            case signOut
            case syncNow
        }
    }

    @Dependency(\.attachments) var attachments
    @Dependency(\.credentials) var credentials
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.uuid) var uuid

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .openPluginsTapped:
                return .send(.delegate(.openPlugins))

            case let .addProviderTapped(kind):
                let provider = Provider(id: uuid(), kind: kind, isEnabled: true)
                state.destination = .providerEditor(.init(provider: provider, isNew: true))
                return .none

            case .deleteAccountTapped:
                state.destination = .alert(.confirmDeleteAccount)
                return .none

            case .deleteAllChatsTapped:
                state.destination = .alert(.confirmDeleteAllChats(isSyncing: state.account != nil))
                return .none

            case .binding, .delegate:
                return .none

            case .destination(.presented(.alert(.confirmDeleteAccount))):
                return .send(.delegate(.deleteAccount))

            case .destination(.presented(.alert(.confirmSignOut))):
                return .send(.delegate(.signOut))

            case .destination(.presented(.alert(.confirmDeleteAllChats))):
                let images = state.conversations.flatMap { $0.messages.flatMap(\.attachments) }
                state.$conversations.withLock { $0.removeAll() }
                return .merge(
                    .run { [attachments] _ in attachments.delete(attachments: images) },
                    .send(.delegate(.allChatsDeleted))
                )

            case let .destination(.presented(.providerEditor(.delegate(.saved(provider, apiKey))))):
                state.$providers.withLock { $0[id: provider.id] = provider }
                state.destination = nil
                return .run { [credentials] send in
                    if provider.kind != .openAI { credentials.setSecret(value: apiKey, id: provider.id) }
                    await send(.delegate(.configurationChanged))
                }

            case let .destination(.presented(.providerEditor(.delegate(.deleted(providerID))))):
                state.destination = nil
                return removeProviders([providerID], from: &state)

            case .destination:
                return .none

            case .doneTapped:
                return .run { [dismiss] _ in await dismiss() }

            case let .providerTapped(providerID):
                guard let provider = state.providers[id: providerID] else { return .none }
                state.destination = .providerEditor(.init(provider: provider, isNew: false))
                return .none

            case let .providerDeleted(providerID):
                return removeProviders([providerID], from: &state)

            case let .signInWithAppleCompleted(credential):
                return .send(.delegate(.signIn(credential)))

            case let .signInWithAppleFailed(message):
                state.$syncStatus.withLock { $0.errorDescription = message }
                return .none

            case .signOutTapped:
                state.destination = .alert(.confirmSignOut)
                return .none

            case .syncNowTapped:
                return .send(.delegate(.syncNow))
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }

    private func removeProviders(_ ids: [Provider.ID], from state: inout State) -> Effect<Action> {
        let orphanedServers = state.mcpServers.filter { server in server.providerID.map(ids.contains) ?? false }.map(\.id)
        state.$providers.withLock { providers in
            ids.forEach { providers.remove(id: $0) }
        }
        state.$mcpServers.withLock { servers in
            orphanedServers.forEach { servers.remove(id: $0) }
        }
        return .run { [credentials] send in
            (ids + orphanedServers).forEach { credentials.setSecret(value: nil, id: $0) }
            await send(.delegate(.configurationChanged))
        }
    }
}

extension SettingsFeature.Destination.State: Equatable {}

extension AlertState where Action == SettingsFeature.Action.Alert {
    static func confirmDeleteAllChats(isSyncing: Bool) -> Self {
        AlertState {
            TextState("Delete All Chats?")
        } actions: {
            ButtonState(role: .destructive, action: .confirmDeleteAllChats) {
                TextState("Delete All")
            }
            ButtonState(role: .cancel) {
                TextState("Cancel")
            }
        } message: {
            TextState(isSyncing
                ? "This permanently removes every conversation on all your devices."
                : "This permanently removes every conversation on this device.")
        }
    }

    static let confirmDeleteAccount = AlertState {
        TextState("Delete Account?")
    } actions: {
        ButtonState(role: .destructive, action: .confirmDeleteAccount) {
            TextState("Delete Account")
        }
        ButtonState(role: .cancel) {
            TextState("Cancel")
        }
    } message: {
        TextState("Your synced providers and chats are deleted from Hestrel’s servers. Everything on this device stays.")
    }

    static let confirmSignOut = AlertState {
        TextState("Sign Out?")
    } actions: {
        ButtonState(action: .confirmSignOut) {
            TextState("Sign Out")
        }
        ButtonState(role: .cancel) {
            TextState("Cancel")
        }
    } message: {
        TextState("Providers and chats stay on this device but stop syncing.")
    }
}
