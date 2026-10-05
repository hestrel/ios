import ComposableArchitecture
import Foundation

@Reducer
struct AppFeature {
    /// The top-level views the sidebar switches between.
    enum Section: Equatable {
        case chat
        case chats
        case artifacts
        case plugins
    }

    /// Detail pages pushed on top of a section.
    @Reducer
    enum Path {
        case artifactDetail(ArtifactDetailFeature)
        case pluginDetail(PluginDetailFeature)
    }

    @ObservableState
    struct State: Equatable {
        var section = Section.chat
        var account = AccountFeature.State()
        var chat = ChatFeature.State()
        var chats = ChatsFeature.State()
        var artifacts = ArtifactsFeature.State()
        var plugins = PluginsFeature.State()
        var sidebar = SidebarFeature.State()
        var path = StackState<Path.State>()
        var isSidebarOpen = false
        @Presents var settings: SettingsFeature.State?
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>
        @Shared(.modelCatalog) var catalog: ModelCatalog
        @Shared(.mcpServers) var mcpServers: IdentifiedArrayOf<MCPServer>
        @Shared(.toolCatalog) var toolCatalog: ToolCatalog
    }

    enum Action: BindableAction {
        case account(AccountFeature.Action)
        case artifacts(ArtifactsFeature.Action)
        case binding(BindingAction<State>)
        case chat(ChatFeature.Action)
        case chats(ChatsFeature.Action)
        case hostServersDiscovered(Result<MCPHostConfig.Discovery, any Error>, for: Provider.ID)
        case plugins(PluginsFeature.Action)
        case modelsLoaded(Result<[ChatModel], any Error>, for: Provider.ID)
        case newChatTapped
        case path(StackActionOf<Path>)
        case refresh
        case refreshTools
        case settings(PresentationAction<SettingsFeature.Action>)
        case sidebar(SidebarFeature.Action)
        case sidebarButtonTapped
        case task
        case toolsLoaded(Result<[MCPTool], any Error>, for: MCPServer.ID)
    }

    nonisolated enum CancelID: Hashable {
        case discovery(Provider.ID)
        case models(Provider.ID)
        case tools(MCPServer.ID)
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.llm) var llm
    @Dependency(\.mcp) var mcp
    @Dependency(\.uuid) var uuid

    var body: some Reducer<State, Action> {
        BindingReducer()
        Scope(state: \.chat, action: \.chat) {
            ChatFeature()
        }
        Scope(state: \.chats, action: \.chats) {
            ChatsFeature()
        }
        Scope(state: \.artifacts, action: \.artifacts) {
            ArtifactsFeature()
        }
        Scope(state: \.plugins, action: \.plugins) {
            PluginsFeature()
        }
        Scope(state: \.sidebar, action: \.sidebar) {
            SidebarFeature()
        }
        Scope(state: \.account, action: \.account) {
            AccountFeature()
        }
        Reduce { state, action in
            // Sync leaves replies alone until they're complete, and the sidebar marks their chats.
            if case .chat = action {
                state.account.streamingMessageIDs = Set(state.chat.responses.values.map(\.messageID))
                state.sidebar.respondingConversationIDs = Set(state.chat.responses.keys)
            }
            return .none
        }
        Reduce { state, action in
            switch action {
            case let .account(.delegate(.synced(report))):
                var effects = report.removedConversationIDs.map { Effect<Action>.send(.chat(.conversationRemoved($0))) }
                if let open = state.chat.conversationID, report.removedConversationIDs.contains(open) {
                    effects.append(startNewConversation(.chat, state: &state))
                }
                if report.providersChanged {
                    effects.append(.send(.refresh))
                }
                return .merge(effects)

            case .account:
                return .none

            case let .artifacts(.delegate(.artifactSelected(artifact))):
                state.path.append(.artifactDetail(ArtifactDetailFeature.State(artifact: artifact)))
                return .none

            case .artifacts, .binding:
                return .none

            case let .chat(.delegate(delegate)):
                switch delegate {
                case let .conversationStarted(id):
                    state.sidebar.selectedConversationID = id
                    state.sidebar.activeDestination = nil
                    return .none
                case .openSettings:
                    state.settings = SettingsFeature.State()
                    return .none
                }

            case .chat:
                return .none

            case let .chats(.delegate(.conversationSelected(id))):
                return openConversation(id, state: &state)

            case let .chats(.delegate(.conversationDeleted(id))):
                return conversationDeleted(id, state: &state)

            case .chats:
                return .none

            case let .hostServersDiscovered(.success(discovery), providerID):
                mergeHostServers(discovery.servers, for: providerID, into: &state)
                state.$toolCatalog.withLock {
                    $0.setDiscovery(.init(status: .ready, skipped: discovery.skipped), for: providerID)
                }
                return .send(.refreshTools)

            case let .hostServersDiscovered(.failure(error), providerID):
                state.$toolCatalog.withLock {
                    $0.setDiscovery(.init(status: .failed(error.localizedDescription)), for: providerID)
                }
                return .none

            case let .plugins(.delegate(delegate)):
                switch delegate {
                case .mcpServersChanged:
                    return .send(.refresh)
                case .openSettings:
                    state.settings = SettingsFeature.State()
                    return .none
                case let .serverSelected(id):
                    state.path.append(.pluginDetail(PluginDetailFeature.State(serverID: id)))
                    return .none
                }

            case .plugins:
                return .none

            case let .modelsLoaded(.success(models), providerID):
                state.$catalog.withLock { $0.update(models, for: providerID) }
                return .none

            case let .modelsLoaded(.failure(error), providerID):
                state.$catalog.withLock { $0.fail(error.localizedDescription, for: providerID) }
                return .none

            case .newChatTapped:
                return startNewConversation(.chat, state: &state)

            case let .path(.element(_, .artifactDetail(.delegate(.openConversation(id))))):
                return openConversation(id, state: &state)

            case .path(.element(_, .pluginDetail(.delegate(.changed)))):
                return .send(.refreshTools)

            case let .path(.element(_, .pluginDetail(.delegate(.edit(serverID))))):
                state.path.removeAll()
                return .send(.plugins(.editTapped(serverID)))

            case .path:
                return .none

            case .refresh, .task:
                return .merge(refreshModels(&state), discoverHostServers(&state), .send(.refreshTools))

            case .refreshTools:
                return refreshTools(&state)

            case .settings(.presented(.delegate(.allChatsDeleted))):
                state.sidebar.selectedConversationID = nil
                let stopReplies = state.chat.responses.keys.map { Effect<Action>.send(.chat(.conversationRemoved($0))) }
                return .merge(stopReplies + [.send(.chat(.startNewConversation(.chat)))])

            case .settings(.presented(.delegate(.openPlugins))):
                state.settings = nil
                show(.plugins, state: &state)
                return .none

            case .settings(.presented(.delegate(.configurationChanged))):
                return .send(.refresh)

            case .settings(.presented(.delegate(.deleteAccount))):
                return .send(.account(.deleteAccount))

            case let .settings(.presented(.delegate(.signIn(credential)))):
                return .send(.account(.signIn(credential)))

            case .settings(.presented(.delegate(.signOut))):
                return .send(.account(.signOut))

            case .settings(.presented(.delegate(.syncNow))):
                return .send(.account(.sync))

            case .settings:
                return .none

            case let .sidebar(.delegate(delegate)):
                state.isSidebarOpen = false
                switch delegate {
                case let .conversationDeleted(id):
                    return conversationDeleted(id, state: &state)
                case let .conversationSelected(id):
                    return openConversation(id, state: &state)
                case let .destinationSelected(destination):
                    switch destination {
                    case .chats:
                        show(.chats, state: &state)
                    case .code:
                        return startNewConversation(.code, state: &state)
                    case .artifacts:
                        show(.artifacts, state: &state)
                    case .plugins:
                        show(.plugins, state: &state)
                    }
                    return .none
                case .newChat:
                    return startNewConversation(.chat, state: &state)
                case .openAccount:
                    state.settings = SettingsFeature.State(path: [.account])
                    return .none
                case .openSettings:
                    state.settings = SettingsFeature.State()
                    return .none
                }

            case .sidebar:
                return .none

            case .sidebarButtonTapped:
                state.isSidebarOpen.toggle()
                return .none

            case let .toolsLoaded(.success(tools), serverID):
                guard let server = state.mcpServers[id: serverID] else { return .none }
                state.$toolCatalog.withLock { $0.update(tools, for: server) }
                return .none

            case let .toolsLoaded(.failure(error), serverID):
                state.$toolCatalog.withLock { $0.fail(error.localizedDescription, for: serverID) }
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.$settings, action: \.settings) {
            SettingsFeature()
        }
    }

    // MARK: Navigation

    /// Switches the main area to a section, the way the sidebar's menu items do.
    private func show(_ section: Section, state: inout State) {
        state.section = section
        state.path.removeAll()
        state.isSidebarOpen = false
        state.sidebar.activeDestination = switch section {
        case .chat: nil
        case .chats: .chats
        case .artifacts: .artifacts
        case .plugins: .plugins
        }
    }

    private func openConversation(_ id: Conversation.ID, state: inout State) -> Effect<Action> {
        show(.chat, state: &state)
        state.sidebar.selectedConversationID = id
        return .send(.chat(.open(id)))
    }

    /// Stops a deleted chat's reply, and leaves the chat if it was open.
    private func conversationDeleted(_ id: Conversation.ID, state: inout State) -> Effect<Action> {
        .merge(
            .send(.chat(.conversationRemoved(id))),
            state.chat.conversationID == id ? .send(.chat(.startNewConversation(.chat))) : .none
        )
    }

    private func startNewConversation(_ kind: Conversation.Kind, state: inout State) -> Effect<Action> {
        show(.chat, state: &state)
        state.sidebar.selectedConversationID = nil
        state.sidebar.activeDestination = kind == .code ? .code : nil
        return .send(.chat(.startNewConversation(kind)))
    }

    // MARK: Loading

    /// Re-fetches the model list of every enabled provider in parallel.
    private func refreshModels(_ state: inout State) -> Effect<Action> {
        let providers = state.providers.filter(\.isEnabled)
        state.$catalog.withLock { $0.beginLoading(Set(providers.ids)) }

        return .merge(
            providers.map { provider in
                .run { [credentials, llm] send in
                    let apiKey = credentials.secret(id: provider.id)
                    let result = await Result {
                        try await llm.listModels(provider: provider, apiKey: apiKey)
                    }
                    await send(.modelsLoaded(result, for: provider.id))
                }
                .cancellable(id: CancelID.models(provider.id), cancelInFlight: true)
            }
        )
    }

    /// Reads the `mcp.json` of every self-hosted provider that publishes one.
    private func discoverHostServers(_ state: inout State) -> Effect<Action> {
        let hosts = state.providers.filter { $0.isEnabled && $0.kind.inheritsMCPServersFromHost && $0.mcpConfigURL.nonBlank != nil }
        let hostIDs = Set(hosts.ids)

        // Hosts that stopped publishing servers take their inherited servers with them.
        state.$mcpServers.withLock { servers in
            servers.removeAll { $0.origin == .host && !hostIDs.contains($0.providerID) }
        }
        state.$toolCatalog.withLock { catalog in
            for provider in state.providers {
                catalog.setDiscovery(hostIDs.contains(provider.id) ? .init(status: .loading) : nil, for: provider.id)
            }
        }

        return .merge(
            hosts.map { provider in
                .run { [mcp] send in
                    let result = await Result { try await mcp.discoverServers(configURL: provider.mcpConfigURL) }
                    await send(.hostServersDiscovered(result, for: provider.id))
                }
                .cancellable(id: CancelID.discovery(provider.id), cancelInFlight: true)
            }
        )
    }

    /// Replaces a host's inherited servers with what it currently publishes, keeping IDs and on/off choices.
    private func mergeHostServers(_ discovered: [DiscoveredMCPServer], for providerID: Provider.ID, into state: inout State) {
        state.$mcpServers.withLock { servers in
            let existing = servers.filter { $0.origin == .host && $0.providerID == providerID }
            for server in existing where !discovered.contains(where: { $0.name == server.name }) {
                servers.remove(id: server.id)
            }
            for entry in discovered {
                if let match = existing.first(where: { $0.name == entry.name }) {
                    servers[id: match.id]?.url = entry.url
                    servers[id: match.id]?.headers = entry.headers
                } else {
                    servers.append(MCPServer(
                        id: uuid(),
                        providerID: providerID,
                        name: entry.name,
                        url: entry.url,
                        origin: .host,
                        headers: entry.headers
                    ))
                }
            }
        }
    }

    /// Lists the tools of every enabled MCP server in parallel.
    private func refreshTools(_ state: inout State) -> Effect<Action> {
        let enabledProviders = Set(state.providers.filter(\.isEnabled).ids)
        let servers = state.mcpServers.filter { $0.isEnabled && enabledProviders.contains($0.providerID) }
        state.$toolCatalog.withLock { $0.beginLoading(Set(servers.ids)) }

        return .merge(
            servers.map { server in
                .run { [credentials, mcp] send in
                    let headers = server.authHeaders(token: credentials.secret(id: server.id))
                    let result = await Result { try await mcp.listTools(server: server, headers: headers) }
                    await send(.toolsLoaded(result, for: server.id))
                }
                .cancellable(id: CancelID.tools(server.id), cancelInFlight: true)
            }
        )
    }
}

extension AppFeature.Path.State: Equatable {}
