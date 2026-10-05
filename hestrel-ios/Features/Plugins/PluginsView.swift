import ComposableArchitecture
import SwiftUI

struct PluginsView: View {
    @Bindable var store: StoreOf<PluginsFeature>

    var body: some View {
        List {
            webSection
            ConnectionsView(store: store.scope(state: \.connections, action: \.connections))

            ForEach(store.groups) { group in
                Section {
                    if let discovery = group.discovery {
                        DiscoveryRow(discovery: discovery)
                    }
                    ForEach(group.servers) { server in
                        serverRow(server)
                    }
                } header: {
                    Label(group.provider.name, systemImage: group.provider.kind.symbol)
                } footer: {
                    Text(group.provider.kind.mcpExecutionDescription)
                }
            }

            Section {
                Button("Add MCP Server", systemImage: "plus") { store.send(.addServerTapped) }
                    .disabled(store.providers.isEmpty)
            } footer: {
                Text(store.providers.isEmpty
                     ? "Add a provider in Settings first."
                     : "Connect your own tools with a Streamable HTTP server URL.")
            }
        }
        .refreshable { store.send(.refreshPulled) }
        .navigationTitle("Plugins")
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
