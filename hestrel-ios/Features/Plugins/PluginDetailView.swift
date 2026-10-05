import ComposableArchitecture
import SwiftUI

@Reducer
struct PluginDetailFeature {
    @ObservableState
    struct State: Equatable {
        let serverID: MCPServer.ID
        @Shared(.mcpServers) var servers: IdentifiedArrayOf<MCPServer>
        @Shared(.toolCatalog) var toolCatalog: ToolCatalog
        @Shared(.providers) var providers: IdentifiedArrayOf<Provider>

        var server: MCPServer? { servers[id: serverID] }
    }

    enum Action {
        case enabledChanged(Bool)
        case editTapped
        case delegate(Delegate)
        enum Delegate: Equatable {
            case changed
            case edit(MCPServer.ID)
        }
    }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case let .enabledChanged(enabled):
                state.$servers.withLock { $0[id: state.serverID]?.isEnabled = enabled }
                return .send(.delegate(.changed))
            case .editTapped:
                return .send(.delegate(.edit(state.serverID)))
            case .delegate:
                return .none
            }
        }
    }
}

struct PluginDetailView: View {
    let store: StoreOf<PluginDetailFeature>

    var body: some View {
        if let server = store.server {
            let tools = store.toolCatalog.tools(for: server.id)
            List {
                Section {
                    Toggle("Enabled", isOn: Binding(
                        get: { server.isEnabled },
                        set: { store.send(.enabledChanged($0)) }
                    ))
                    .tint(.toggleTint)
                    LabeledContent("URL", value: server.url)
                    LabeledContent("Provider", value: store.providers[id: server.providerID]?.name ?? "—")
                    LabeledContent("Source", value: server.origin == .host ? "Host configuration" : "Added manually")
                    if case let .failed(message) = store.toolCatalog.statuses[server.id] {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Tools") {
                    if tools.isEmpty {
                        Text(server.isEnabled ? "No tools loaded." : "Enable this plugin to load its tools.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.system(.body, design: .monospaced))
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(server.origin == .host ? "Configuration" : "Edit") { store.send(.editTapped) }
                }
            }
        } else {
            ContentUnavailableView("Plugin Removed", systemImage: "puzzlepiece.extension")
        }
    }
}
