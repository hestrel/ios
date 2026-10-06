import ComposableArchitecture
import SwiftUI

struct PluginsView: View {
    @Bindable var store: StoreOf<PluginsFeature>

    var body: some View {
        List {
            computersSection
            webSection
            ConnectionsView(store: store.scope(state: \.connections, action: \.connections))
            connectorsSection

            ForEach(store.groups) { group in
                Section {
                    if let discovery = group.discovery {
                        DiscoveryRow(discovery: discovery)
                    }
                    ForEach(group.servers) { server in
                        serverRow(server)
                    }
                } header: {
                    Label(group.title, systemImage: group.symbol)
                } footer: {
                    if let footer = group.footer { Text(footer) }
                }
            }

            Section {
                Button("Add MCP Server", systemImage: "plus") { store.send(.addServerTapped) }
            } footer: {
                Text("Connect your own tools with a Streamable HTTP server URL.")
            }
        }
        .refreshable { store.send(.refreshPulled) }
        .onAppear { store.send(.appeared) }
        .navigationTitle("Plugins")
        .alert("Connect \(Connector.named(store.tokenPromptID)?.name ?? "")", isPresented: isTokenPromptPresented) {
            SecureField("Personal access token", text: $store.tokenDraft)
            Button("Cancel", role: .cancel) { store.send(.tokenCancelled) }
            Button("Connect") { store.send(.tokenSubmitted) }
        } message: {
            Text("Paste a personal access token. It stays in this device’s Keychain.")
        }
        .sheet(item: $store.scope(state: \.editor, action: \.editor)) { editor in
            NavigationStack {
                MCPServerEditorView(store: editor)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { store.send(.closeEditor) }
                        }
                    }
            }
        }
    }

    /// Computers paired with the account, running Hestrel's bridge for the Code tab.
    private var computersSection: some View {
        Section {
            ForEach(store.computerServers) { server in
                computerRow(server)
            }
            Button("Pair a Computer", systemImage: "qrcode.viewfinder") { store.send(.pairComputerTapped) }
            if let error = store.computerError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Computers")
        } footer: {
            Text(store.account == nil
                ? "Sign in to Hestrel to pair computers. Their coding agents then work on all your devices, from anywhere."
                : "Run Codex or Claude Code on your computers from the Code tab, on every device signed in to your account.")
        }
    }

    private func computerRow(_ server: MCPServer) -> some View {
        let computer = store.computers[id: server.id]
        return HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "desktopcomputer")
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .background(Color.fill, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.xSmall) {
                    Circle()
                        .fill(computer?.online == true ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(computerSubtitle(computer))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if store.removingComputerID == server.id {
                ProgressView()
            } else {
                Toggle("Enable \(server.name)", isOn: Binding(
                    get: { server.isEnabled },
                    set: { store.send(.serverToggled(server.id, isEnabled: $0)) }
                ))
                .labelsHidden()
                .tint(.toggleTint)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", systemImage: "trash") { store.send(.computerRemoveTapped(server.id)) }
                .tint(.red)
        }
        .contextMenu {
            Button("Remove from Account", systemImage: "trash") { store.send(.computerRemoveTapped(server.id)) }
        }
    }

    private func computerSubtitle(_ computer: Computer?) -> String {
        guard let computer else { return "Offline" }
        let agents = store.toolCatalog.codeAgents(on: computer.id).map(\.title).formatted(.list(type: .and))
        guard computer.online else { return "Offline" }
        return agents.isEmpty ? "Online" : "Online · \(agents)"
    }

    private var connectorsSection: some View {
        Section {
            ForEach(Connector.directory) { connector in
                connectorRow(connector)
            }
        } header: {
            Text("Connectors")
        } footer: {
            if let error = store.connectorError {
                Text(error)
            } else {
                Text("Works with every provider. You sign in on each service’s own page, and tokens stay in this device’s Keychain.")
            }
        }
    }

    private func connectorRow(_ connector: Connector) -> some View {
        let server = store.servers.first { $0.connectorID == connector.id }

        return HStack(spacing: Theme.Spacing.medium) {
            LogoTile(image: Image(connector.logoAsset))
            VStack(alignment: .leading, spacing: 1) {
                Text(connector.name)
                Text(connectorSubtitle(connector, server: server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let server {
                Toggle("Enable \(connector.name)", isOn: Binding(
                    get: { server.isEnabled },
                    set: { store.send(.serverToggled(server.id, isEnabled: $0)) }
                ))
                .labelsHidden()
                .tint(.toggleTint)
            } else if store.connectingID == connector.id {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") { store.send(.connectorTapped(connector.id)) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(store.connectingID != nil)
                    .accessibilityLabel("Connect \(connector.name)")
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            if let server { store.send(.serverTapped(server.id)) }
        }
        .contextMenu {
            if server != nil {
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                    store.send(.connectorDisconnectTapped(connector.id))
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if server != nil {
                Button("Disconnect", systemImage: "xmark.circle") {
                    store.send(.connectorDisconnectTapped(connector.id))
                }
                .tint(.red)
            }
        }
    }

    private func connectorSubtitle(_ connector: Connector, server: MCPServer?) -> String {
        guard let server else { return connector.summary }
        guard server.isEnabled else { return "Connected · Off" }
        switch store.toolCatalog.statuses[server.id] {
        case let .failed(message): return message
        case .ready:
            let count = store.toolCatalog.tools(for: server.id).count
            return "Connected · \(count) \(count == 1 ? "tool" : "tools")"
        case .loading, nil: return "Connected"
        }
    }

    private var isTokenPromptPresented: Binding<Bool> {
        Binding(
            get: { store.tokenPromptID != nil },
            set: { if !$0 { store.send(.tokenCancelled) } }
        )
    }

    private var webSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "globe")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 32)
                    .background(Color.fill, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Web search")
                    Text("Search and read web pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Toggle("Web search", isOn: Binding(
                    get: { store.isWebSearchEnabled },
                    set: { store.send(.webSearchToggled($0)) }
                ))
                .labelsHidden()
                .tint(.toggleTint)
            }
        } header: {
            Text("Web")
        } footer: {
            Text("Works with every provider. OpenAI and Anthropic search on their own servers; for the rest, Hestrel searches DuckDuckGo and reads pages on this device.")
        }
    }

    private func serverRow(_ server: MCPServer) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button { store.send(.serverTapped(server.id)) } label: {
                MCPServerRow(
                    server: server,
                    status: store.toolCatalog.statuses[server.id],
                    toolCount: store.toolCatalog.tools(for: server.id).count
                )
            }
            .buttonStyle(.plain)
            Toggle("Enable \(server.name)", isOn: Binding(
                get: { server.isEnabled },
                set: { store.send(.serverToggled(server.id, isEnabled: $0)) }
            ))
            .labelsHidden()
            .tint(.toggleTint)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { store.send(.editTapped(server.id)) }
        }
        .swipeActions(edge: .trailing) {
            Button("Edit", systemImage: "pencil") { store.send(.editTapped(server.id)) }
                .tint(.gray)
        }
    }
}

struct MCPServerRow: View {
    let server: MCPServer
    let status: LoadStatus?
    let toolCount: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .background(Color.fill, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(server.name)
                        .lineLimit(1)
                    if server.origin == .host {
                        Text("Host")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.fill, in: .capsule)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status == .loading, server.isEnabled {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(.rect)
    }

    private var subtitle: String {
        guard server.isEnabled else { return "\(server.displayHost) · Off" }
        switch status {
        case let .failed(message): return message
        case .ready: return "\(server.displayHost) · \(toolCount) \(toolCount == 1 ? "tool" : "tools")"
        case .loading, nil: return server.displayHost
        }
    }
}

private struct DiscoveryRow: View {
    let discovery: ToolCatalog.Discovery

    var body: some View {
        Label {
            switch discovery.status {
            case .loading:
                Text("Reading the host’s mcp.json…")
            case .ready:
                Text(discovery.skipped.isEmpty
                     ? "Inherited from the host’s mcp.json"
                     : "From the host’s mcp.json · skipped \(discovery.skipped.joined(separator: ", ")) (stdio)")
            case let .failed(message):
                Text(message)
            }
        } icon: {
            Image(systemName: discovery.status == .ready ? "arrow.down.circle" : "exclamationmark.triangle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
}
