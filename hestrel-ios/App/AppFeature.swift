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
        @Presents var pairing: PairComputerFeature.State?
        @Shared(.account) var signedInAccount: Account?
        @Shared(.computers) var computers: IdentifiedArrayOf<Computer>
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
        case becameActive
        case computersLoaded(Result<[Computer], any Error>)
        case openURL(URL)
        case pairComputer(code: String?)
        case pairing(PresentationAction<PairComputerFeature.Action>)
        case refreshComputers
        case settings(PresentationAction<SettingsFeature.Action>)
        case sidebar(SidebarFeature.Action)
        case sidebarButtonTapped
        case task
        case toolsLoaded(Result<[MCPTool], any Error>, for: MCPServer.ID)
    }

    nonisolated enum CancelID: Hashable {
        case computers
        case discovery(Provider.ID)
        case models(Provider.ID)
        case tools(MCPServer.ID)
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.hestrelAPI) var api
    @Dependency(\.llm) var llm
    @Dependency(\.mcp) var mcp
    @Dependency(\.mcpAuth) var mcpAuth
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
                // Computers paired on another device show up with the account's other changes.
                effects.append(report.providersChanged ? .send(.refresh) : .send(.refreshComputers))
                return .merge(effects)

            case .account(.signOut), .account(.deleteAccountFinished(.success)):
                return .send(.computersLoaded(.success([])))

            case .account:
                return .none

            case .becameActive:
                // Computers come and go while Hestrel is in the background.
                return .send(.refreshComputers)

            case let .computersLoaded(.success(computers)):
                // A computer that just came online has agents to offer, which failed to load while it was away.
                let cameOnline = computers.contains { computer in computer.online && state.computers[id: computer.id]?.online != true }
                state.$computers.withLock { $0 = IdentifiedArray(uniqueElements: computers) }
                let serversChanged = mergeComputerServers(computers, state: &state)
                return serversChanged || cameOnline ? .send(.refreshTools) : .none

            case .computersLoaded(.failure):
                // Offline or signed out elsewhere: keep what's known until the next refresh.
                return .none

            case let .openURL(url):
                guard url.scheme?.lowercased() == "hestrel", url.host()?.lowercased() == "pair" else { return .none }
                return .send(.pairComputer(code: PairingLink.code(from: url.absoluteString)))

            case let .pairComputer(code):
                state.settings = nil
                state.isSidebarOpen = false
                state.pairing = PairComputerFeature.State(code: code)
                return .none

            case let .pairing(.presented(.delegate(.paired(computer)))):
                var computers = state.computers
                computers[id: computer.id] = computer
                return .send(.computersLoaded(.success(Array(computers))))

            case .pairing(.presented(.delegate(.openAccount))):
                state.pairing = nil
                state.settings = SettingsFeature.State(path: [.account])
                return .none

            case .pairing:
                return .none

            case .refreshComputers:
                guard state.signedInAccount != nil else { return .send(.computersLoaded(.success([]))) }
                return .run { [api, credentials] send in
                    let result = await Result {
                        guard let token = credentials.secret(id: Account.sessionTokenID) else { throw HestrelAPIError.unauthorized }
                        return try await api.listComputers(token: token)
                    }
                    await send(.computersLoaded(result))
                }
                .cancellable(id: CancelID.computers, cancelInFlight: true)

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
                case .openPlugins:
                    show(.plugins, state: &state)
                    return .none
                case .openSettings:
                    state.settings = SettingsFeature.State()
                    return .none
                case .pairComputer:
                    return .send(.pairComputer(code: nil))
                case .refreshComputers:
                    return .send(.refreshComputers)
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
                case .pairComputer:
                    return .send(.pairComputer(code: nil))
                case .refreshComputers:
                    return .send(.refreshComputers)
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

            case .task:
                // Replies still running on a computer when the app last quit carry on where they are.
                return .merge(.send(.refresh), .send(.chat(.resumePendingTurns)))

            case .refresh:
                return .merge(refreshModels(&state), discoverHostServers(&state), .send(.refreshTools), .send(.refreshComputers))

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
        .ifLet(\.$pairing, action: \.pairing) {
            PairComputerFeature()
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

    /// Keeps one MCP server per paired computer, enabled from the start. Returns whether anything changed.
    private func mergeComputerServers(_ computers: [Computer], state: inout State) -> Bool {
        let before = state.mcpServers.filter { $0.origin == .computer }
        state.$mcpServers.withLock { servers in
            servers.removeAll { $0.origin == .computer && !computers.map(\.id).contains($0.id) }
            for computer in computers {
                if let existing = servers[id: computer.id] {
                    servers[id: computer.id] = .computer(computer, isEnabled: existing.isEnabled)
                } else {
                    servers.append(.computer(computer))
                }
            }
        }
        return before != state.mcpServers.filter { $0.origin == .computer }
    }

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
            servers.removeAll { server in
                server.origin == .host && !(server.providerID.map(hostIDs.contains) ?? false)
            }
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
        // Servers for every provider (connectors) load whenever they're on.
        let servers = state.mcpServers.filter { server in
            server.isEnabled && (server.providerID.map(enabledProviders.contains) ?? true)
        }
        state.$toolCatalog.withLock { $0.beginLoading(Set(servers.ids)) }

        return .merge(
            servers.map { server in
                .run { [mcp, mcpAuth] send in
                    let result = await Result {
                        try await mcp.listTools(server: server, headers: mcpAuth.headers(server: server))
                    }
                    await send(.toolsLoaded(result, for: server.id))
                }
                .cancellable(id: CancelID.tools(server.id), cancelInFlight: true)
            }
        )
    }
}

extension AppFeature.Path.State: Equatable {}
