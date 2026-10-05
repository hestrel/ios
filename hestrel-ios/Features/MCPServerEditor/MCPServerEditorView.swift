import ComposableArchitecture
import SwiftUI

struct MCPServerEditorView: View {
    @Bindable var store: StoreOf<MCPServerEditorFeature>

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $store.server.name)
                    .autocorrectionDisabled()
                Picker("Provider", selection: $store.server.providerID) {
                    ForEach(store.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                Toggle("Enabled", isOn: $store.server.isEnabled)
                    .tint(.toggleTint)
            } footer: {
                if let provider = store.providers[id: store.server.providerID] {
                    Text(provider.kind.mcpExecutionDescription)
                }
            }
            .disabled(store.isReadOnly)

            Section {
                TextField("Server URL", text: $store.server.url, prompt: Text("https://example.com/mcp"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(store.isReadOnly)
                if !store.isReadOnly {
                    SecureField("Bearer Token (optional)", text: $store.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(store.isReadOnly
                     ? "This server comes from the host’s MCP configuration. Change it there."
                     : "Streamable HTTP servers only. Tokens are stored in the Keychain.")
            }

            Section {
                Button {
                    store.send(.testConnectionTapped)
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        connectionStatus
                    }
                }
                .disabled(!store.server.hasValidURL || store.connection == .testing)
            } footer: {
                if case let .failed(message) = store.connection {
                    Text(message)
                }
            }

            if !store.isNew && !store.isReadOnly {
                Section {
                    Button("Delete Server", role: .destructive) {
                        store.send(.deleteTapped)
                    }
                }
            }
        }
        .navigationTitle(store.isNew ? "Add custom MCP server" : store.server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.isReadOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        store.send(.saveTapped)
                    }
                    .disabled(!store.canSave)
                }
            }
        }
        .task { await store.send(.task).finish() }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch store.connection {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case let .succeeded(toolCount):
            Label("^[\(toolCount) tool](inflect: true)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}
