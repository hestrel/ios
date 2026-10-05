import AuthenticationServices
import ComposableArchitecture
import Foundation

@Reducer
struct ProviderEditorFeature {
    @ObservableState
    struct State: Equatable {
        var provider: Provider
        var apiKey = ""
        var chatGPTEmail: String?
        var isChatGPTConnected = false
        var hasChatGPTRegistration = false
        var isAuthorizing = false
        var showPlanNotice = false
        var authError: String?
        let isNew: Bool
        var connection = ConnectionStatus.idle

        var canSave: Bool {
            provider.name.nonBlank != nil
                && provider.hasValidBaseURL
                && (!provider.kind.requiresAPIKey || apiKey.nonBlank != nil)
                && (provider.kind != .openAI || isChatGPTConnected || !provider.isEnabled)
                && !isAuthorizing
        }
    }

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case succeeded(modelCount: Int)
        case failed(String)
    }

    enum Action: BindableAction {
        case apiKeyLoaded(String?)
        case chatGPTLoaded(email: String?, connected: Bool, registered: Bool)
        case connectChatGPTTapped
        case chatGPTConnected(Result<String?, any Error>)
        case disconnectChatGPTTapped
        case chatGPTDisconnected(Result<Void, any Error>)
        case binding(BindingAction<State>)
        case connectionTested(Result<Int, any Error>)
        case delegate(Delegate)
        case deleteTapped
        case saveTapped
        case task
        case testConnectionTapped

        enum Delegate: Equatable {
            case deleted(Provider.ID)
            case saved(Provider, apiKey: String)
        }
    }

    nonisolated enum CancelID: Hashable {
        case connectionTest
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.llm) var llm
    @Dependency(\.chatGPT) var chatGPT

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case let .chatGPTLoaded(email, connected, registered):
                state.chatGPTEmail = email
                state.isChatGPTConnected = connected
                state.hasChatGPTRegistration = registered
                return .none

            case .connectChatGPTTapped:
                guard !state.isAuthorizing else { return .none }
                state.isAuthorizing = true
                state.authError = nil
                return .run { [chatGPT, id = state.provider.id] send in
                    await send(.chatGPTConnected(Result { try await chatGPT.signIn(id).email }))
                }

            case let .chatGPTConnected(.success(email)):
                state.isAuthorizing = false
                state.chatGPTEmail = email
                state.isChatGPTConnected = true
                state.provider.isEnabled = true
                state.provider.baseURL = ProviderKind.openAI.defaultBaseURL
                state.showPlanNotice = !state.hasChatGPTRegistration
                state.hasChatGPTRegistration = true
                state.connection = .idle
                return .none

            case let .chatGPTConnected(.failure(error)):
                state.isAuthorizing = false
                if !(error is CancellationError), (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    state.authError = error.localizedDescription
                }
                return .none

            case .disconnectChatGPTTapped:
                guard !state.isAuthorizing else { return .none }
                state.isAuthorizing = true
                state.authError = nil
                return .run { [chatGPT, id = state.provider.id] send in
                    await send(.chatGPTDisconnected(Result { try await chatGPT.signOut(id) }))
                }

            case let .chatGPTDisconnected(result):
                state.isAuthorizing = false
                state.isChatGPTConnected = false
                state.provider.isEnabled = false
                state.connection = .idle
                if case let .failure(error) = result { state.authError = error.localizedDescription }
                return .none

            case let .apiKeyLoaded(apiKey):
                state.apiKey = apiKey ?? ""
                return .none

            case .binding(\.apiKey):
                // Entering a key is the clearest signal the user wants to use this provider.
                if state.apiKey.nonBlank != nil {
                    state.provider.isEnabled = true
                }
                state.connection = .idle
                return .cancel(id: CancelID.connectionTest)

            case .binding(\.provider.baseURL), .binding(\.provider.mcpConfigURL):
                state.connection = .idle
                return .cancel(id: CancelID.connectionTest)

            case .binding, .delegate:
                return .none

            case let .connectionTested(.success(modelCount)):
                state.connection = .succeeded(modelCount: modelCount)
                return .none

            case let .connectionTested(.failure(error)):
                state.connection = .failed(error.localizedDescription)
                return .none

            case .deleteTapped:
                return .send(.delegate(.deleted(state.provider.id)))

            case .saveTapped:
                guard state.canSave else { return .none }
                state.provider.name = state.provider.name.trimmed
                state.provider.baseURL = state.provider.baseURL.trimmed
                return .send(.delegate(.saved(state.provider, apiKey: state.apiKey.trimmed)))

            case .task:
                if state.provider.kind == .openAI {
                    return .run { [chatGPT, id = state.provider.id] send in
                        let session = await chatGPT.session(id)
                        await send(.chatGPTLoaded(email: session?.email, connected: session?.isConnected == true, registered: session != nil))
                    }
                }
                guard !state.isNew else { return .none }
                return .run { [providerID = state.provider.id, credentials] send in
                    await send(.apiKeyLoaded(credentials.secret(id: providerID)))
                }

            case .testConnectionTapped:
                state.connection = .testing
                return .run { [provider = state.provider, apiKey = state.apiKey.nonBlank, llm] send in
                    await send(.connectionTested(Result {
                        try await llm.listModels(provider: provider, apiKey: apiKey).count
                    }))
                }
                .cancellable(id: CancelID.connectionTest, cancelInFlight: true)
            }
        }
    }
}
