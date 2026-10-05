import ComposableArchitecture
import Foundation

/// Connected apps and custom plugins, managed from one screen.
@Reducer
struct PluginsFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.mcpServers) var servers: IdentifiedArrayOf<MCPServer>
        @Shared(.toolCatalog) var toolCatalog: ToolCatalog
        @Shared(.webSearchEnabled) var isWebSearchEnabled: Bool

        var connections = ConnectionsFeature.State()
        @Presents var editor: MCPServerEditorFeature.State?

        var groups: [ServerGroup] {
            providers.compactMap { provider -> ServerGroup? in
                let servers = servers.filter { $0.providerID == provider.id }
                let discovery = toolCatalog.discoveryStatuses[provider.id]
                guard !servers.isEmpty || discovery != nil else { return nil }
                return ServerGroup(provider: provider, servers: Array(servers), discovery: discovery)
            }
        }
    }

    struct ServerGroup: Equatable, Identifiable {
        let provider: Provider
        let servers: [MCPServer]
        let discovery: ToolCatalog.Discovery?
        var id: Provider.ID { provider.id }
    }

    enum Action {
        case delegate(Delegate)
        case addServerTapped
        case connections(ConnectionsFeature.Action)
        case editor(PresentationAction<MCPServerEditorFeature.Action>)
        case editTapped(MCPServer.ID)
        case closeEditor
        case refreshPulled
        case serverTapped(MCPServer.ID)
        case serverToggled(MCPServer.ID, isEnabled: Bool)
        case webSearchToggled(Bool)

        enum Delegate: Equatable {
            case mcpServersChanged
            case openSettings
            case serverSelected(MCPServer.ID)
        }
    }

    @Dependency(\.uuid) var uuid
    @Dependency(\.credentials) var credentials

    var body: some Reducer<State, Action> {
        Scope(state: \.connections, action: \.connections) { ConnectionsFeature() }
        Reduce { state, action in
            switch action {
            case .delegate:
                return .none
            case .addServerTapped:
                guard let provider = state.providers.first(where: \.isEnabled) ?? state.providers.first else {
                    return .send(.delegate(.openSettings))
                }
                state.editor = .init(server: MCPServer(id: uuid(), providerID: provider.id), isNew: true)
                return .none
            case let .editTapped(id):
                guard let server = state.servers[id: id] else { return .none }
                state.editor = .init(server: server, isNew: false)
                return .none
            case .closeEditor:
                state.editor = nil
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
            case .editor, .connections:
                return .none
            case .refreshPulled:
                return .send(.delegate(.mcpServersChanged))
            case let .serverTapped(id):
                return .send(.delegate(.serverSelected(id)))
            case let .serverToggled(id, isEnabled):
                state.$servers.withLock { $0[id: id]?.isEnabled = isEnabled }
                return .send(.delegate(.mcpServersChanged))
            case let .webSearchToggled(isEnabled):
                state.$isWebSearchEnabled.withLock { $0 = isEnabled }
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) { MCPServerEditorFeature() }
    }
}
