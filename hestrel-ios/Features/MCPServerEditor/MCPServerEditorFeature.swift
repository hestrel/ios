import ComposableArchitecture
import Foundation

@Reducer
struct MCPServerEditorFeature {
    @ObservableState
    struct State: Equatable {
        var server: MCPServer
        var token = ""
        let isNew: Bool
        var connection = ConnectionStatus.idle
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>

        /// Servers inherited from a host are configured on the host, not here.
        var isReadOnly: Bool { server.origin != .manual }

        var canSave: Bool {
            server.name.nonBlank != nil && server.hasValidURL && (server.providerID.map { providers[id: $0] != nil } ?? true)
        }
    }

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case succeeded(toolCount: Int)
        case failed(String)
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case connectionTested(Result<Int, any Error>)
        case delegate(Delegate)
        case deleteTapped
        case saveTapped
        case task
        case testConnectionTapped
        case tokenLoaded(String?)

        enum Delegate: Equatable {
            case deleted(MCPServer.ID)
            case saved(MCPServer, token: String)
        }
    }

    nonisolated enum CancelID: Hashable {
        case connectionTest
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.mcp) var mcp

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.server.url), .binding(\.token):
                state.connection = .idle
                return .cancel(id: CancelID.connectionTest)

            case .binding, .delegate:
                return .none

            case let .connectionTested(.success(toolCount)):
                state.connection = .succeeded(toolCount: toolCount)
                return .none

            case let .connectionTested(.failure(error)):
                state.connection = .failed(error.localizedDescription)
                return .none

            case .deleteTapped:
                return .send(.delegate(.deleted(state.server.id)))

            case .saveTapped:
                guard state.canSave else { return .none }
                state.server.name = state.server.name.trimmed
                state.server.url = state.server.url.trimmed
                return .send(.delegate(.saved(state.server, token: state.token.trimmed)))

            case .task:
                guard !state.isNew else { return .none }
                return .run { [serverID = state.server.id, credentials] send in
                    await send(.tokenLoaded(credentials.secret(id: serverID)))
                }

            case .testConnectionTapped:
                state.connection = .testing
                let headers = state.server.authHeaders(token: state.token)
                return .run { [server = state.server, mcp] send in
                    await send(.connectionTested(Result {
                        try await mcp.listTools(server: server, headers: headers).count
                    }))
                }
                .cancellable(id: CancelID.connectionTest, cancelInFlight: true)

            case let .tokenLoaded(token):
                state.token = token ?? ""
                return .none
            }
        }
    }
}
