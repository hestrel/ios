import ComposableArchitecture
import Foundation

/// Web search, connected apps and custom MCP servers, managed from one screen.
@Reducer
struct PluginsFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.mcpServers) var servers: IdentifiedArrayOf<MCPServer>
        @Shared(.toolCatalog) var toolCatalog: ToolCatalog
        @Shared(.webSearchEnabled) var isWebSearchEnabled: Bool
        @Shared(.computers) var computers: IdentifiedArrayOf<Computer>
        @Shared(.account) var account: Account?
        /// The computer being removed from the account.
        var removingComputerID: Computer.ID?
        var computerError: String?

        var connections = ConnectionsFeature.State()
        @Presents var editor: MCPServerEditorFeature.State?

        /// The connector whose sign-in is in progress.
        var connectingID: Connector.ID?
        var connectorError: String?
        /// The token-based connector waiting for the user to paste a token.
        var tokenPromptID: Connector.ID?
        var tokenDraft = ""

        func server(for connector: Connector) -> MCPServer? {
            servers.first { $0.connectorID == connector.id }
        }

        /// MCP servers of the computers paired with the account.
        var computerServers: [MCPServer] {
            servers.filter { $0.origin == .computer }
        }

        /// Hand-added and host-inherited servers, grouped by the provider they belong to.
        var groups: [ServerGroup] {
            let custom = servers.filter { $0.connectorID == nil && $0.origin != .computer }
            var groups: [ServerGroup] = []
            let shared = custom.filter { $0.providerID == nil }
            if !shared.isEmpty {
                groups.append(ServerGroup(id: "all", title: "All providers", symbol: "square.stack.3d.up",
                                          footer: nil, servers: Array(shared), discovery: nil))
            }
            for provider in providers {
                let servers = custom.filter { $0.providerID == provider.id }
                let discovery = toolCatalog.discoveryStatuses[provider.id]
                guard !servers.isEmpty || discovery != nil else { continue }
                groups.append(ServerGroup(id: provider.id.uuidString, title: provider.name, symbol: provider.kind.symbol,
                                          footer: provider.kind.mcpExecutionDescription, servers: Array(servers), discovery: discovery))
            }
            return groups
        }
    }

    struct ServerGroup: Equatable, Identifiable {
        let id: String
        let title: String
        let symbol: String
        let footer: String?
        let servers: [MCPServer]
        let discovery: ToolCatalog.Discovery?
    }

    enum Action: BindableAction {
        case addServerTapped
        case appeared
        case binding(BindingAction<State>)
        case closeEditor
        case computerRemoved(Computer.ID, Result<Void, any Error>)
        case computerRemoveTapped(Computer.ID)
        case pairComputerTapped
        case connectorConnected(Result<MCPServer, any Error>)
        case connectorDisconnectTapped(Connector.ID)
        case connectorTapped(Connector.ID)
        case connections(ConnectionsFeature.Action)
        case delegate(Delegate)
        case editor(PresentationAction<MCPServerEditorFeature.Action>)
        case editTapped(MCPServer.ID)
        case refreshPulled
        case serverTapped(MCPServer.ID)
        case serverToggled(MCPServer.ID, isEnabled: Bool)
        case tokenCancelled
        case tokenSubmitted
        case webSearchToggled(Bool)

        enum Delegate: Equatable {
            case mcpServersChanged
            case openSettings
            case pairComputer
            case refreshComputers
            case serverSelected(MCPServer.ID)
        }
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.hestrelAPI) var api
    @Dependency(\.mcpAuth) var mcpAuth
    @Dependency(\.uuid) var uuid

    var body: some Reducer<State, Action> {
        BindingReducer()
        Scope(state: \.connections, action: \.connections) { ConnectionsFeature() }
        Reduce { state, action in
            switch action {
            case .addServerTapped:
                let provider = state.providers.first(where: \.isEnabled) ?? state.providers.first
                state.editor = .init(server: MCPServer(id: uuid(), providerID: provider?.id), isNew: true)
                return .none

            case .binding, .connections, .delegate:
                return .none

            case .closeEditor:
                state.editor = nil
                return .none

            case let .connectorConnected(.success(server)):
                state.connectingID = nil
                state.$servers.withLock { servers in
                    // One server per connector, even if a sign-in raced another.
                    servers.removeAll { $0.connectorID != nil && $0.connectorID == server.connectorID }
                    servers[id: server.id] = server
                }
                return .send(.delegate(.mcpServersChanged))

            case let .connectorConnected(.failure(error)):
                state.connectingID = nil
                if !error.isWebAuthenticationCancellation {
                    state.connectorError = error.localizedDescription
                }
                return .none

            case let .connectorDisconnectTapped(connectorID):
                guard let connector = Connector.named(connectorID), let server = state.server(for: connector) else { return .none }
                state.$servers.withLock { _ = $0.remove(id: server.id) }
                return .run { [mcpAuth] send in
                    await mcpAuth.signOut(server: server)
                    await send(.delegate(.mcpServersChanged))
                }

            case let .connectorTapped(connectorID):
                guard state.connectingID == nil,
                      let connector = Connector.named(connectorID),
                      state.server(for: connector) == nil
                else { return .none }
                state.connectorError = nil
                let server = MCPServer(id: uuid(), providerID: nil, connectorID: connector.id, name: connector.name, url: connector.url)
                switch connector.auth {
                case .oauth:
                    state.connectingID = connector.id
                    return .run { [mcpAuth] send in
                        await send(.connectorConnected(Result {
                            try await mcpAuth.signIn(server: server)
                            return server
                        }))
                    }
                case .token:
                    state.tokenPromptID = connector.id
                    state.tokenDraft = ""
                    return .none
                case .none:
                    return .send(.connectorConnected(.success(server)))
                }

            case let .editTapped(id):
                // Connectors are managed by their sign-in, not edited by hand.
                guard let server = state.servers[id: id], server.connector == nil else { return .none }
                state.editor = .init(server: server, isNew: false)
                return .none

            case let .editor(.presented(.delegate(.saved(server, token)))):
                state.$servers.withLock { $0[id: server.id] = server }
                state.editor = nil
                return .run { [credentials] send in
                    credentials.setSecret(value: token, id: server.id)
                    await send(.delegate(.mcpServersChanged))
                }

            case let .editor(.presented(.delegate(.deleted(id)))):
                state.$servers.withLock { _ = $0.remove(id: id) }
                state.editor = nil
                return .run { [credentials] send in
                    credentials.setSecret(value: nil, id: id)
                    await send(.delegate(.mcpServersChanged))
                }

            case .editor:
                return .none

            case .appeared:
                return .send(.delegate(.refreshComputers))

            case .refreshPulled:
                return .merge(.send(.delegate(.mcpServersChanged)), .send(.delegate(.refreshComputers)))

            case .pairComputerTapped:
                return .send(.delegate(.pairComputer))

            case let .computerRemoveTapped(id):
                state.removingComputerID = id
                state.computerError = nil
                return .run { [api, credentials] send in
                    let result = await Result {
                        guard let token = credentials.secret(id: Account.sessionTokenID) else { throw HestrelAPIError.unauthorized }
                        try await api.removeComputer(token: token, id: id)
                    }
                    await send(.computerRemoved(id, result))
                }

            case .computerRemoved(_, .success):
                state.removingComputerID = nil
                return .send(.delegate(.refreshComputers))

            case let .computerRemoved(_, .failure(error)):
                state.removingComputerID = nil
                state.computerError = error.localizedDescription
                return .none

            case let .serverTapped(id):
                return .send(.delegate(.serverSelected(id)))

            case let .serverToggled(id, isEnabled):
                state.$servers.withLock { $0[id: id]?.isEnabled = isEnabled }
                return .send(.delegate(.mcpServersChanged))

            case .tokenCancelled:
                state.tokenPromptID = nil
                state.tokenDraft = ""
                return .none

            case .tokenSubmitted:
                guard let connector = Connector.named(state.tokenPromptID), let token = state.tokenDraft.nonBlank else { return .none }
                state.tokenPromptID = nil
                state.tokenDraft = ""
                let server = MCPServer(id: uuid(), providerID: nil, connectorID: connector.id, name: connector.name, url: connector.url)
                return .run { [credentials] send in
                    credentials.setSecret(value: token, id: server.id)
                    await send(.connectorConnected(.success(server)))
                }

            case let .webSearchToggled(isEnabled):
                state.$isWebSearchEnabled.withLock { $0 = isEnabled }
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) { MCPServerEditorFeature() }
    }
}
