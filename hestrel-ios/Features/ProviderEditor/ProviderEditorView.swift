import ComposableArchitecture
import SwiftUI

struct ProviderEditorView: View {
    @Bindable var store: StoreOf<ProviderEditorFeature>

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $store.provider.name)
                LabeledContent("Type", value: store.provider.kind.displayName)
                Toggle("Enabled", isOn: $store.provider.isEnabled)
                    .tint(.toggleTint)
            }

            if store.provider.kind == .openAI {
                chatGPTSection
            } else {
                Section {
                    TextField("Base URL", text: $store.provider.baseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(store.provider.kind.requiresAPIKey ? "API Key" : "API Key (optional)", text: $store.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Connection")
                } footer: {
                    Text(LocalizedStringKey(store.provider.kind.setupHint))
                }
            }

            if store.provider.kind.inheritsMCPServersFromHost {
                Section {
                    TextField("MCP Config URL", text: $store.provider.mcpConfigURL, prompt: Text("http://192.168.1.10:8000/mcp.json"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Plugins")
                } footer: {
                    Text("Hestrel inherits the MCP servers this host publishes in an mcp.json (Claude Desktop, LM Studio or VS Code format). “localhost” entries resolve to the host, and only HTTP servers are supported.")
                }
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
                .disabled(!store.provider.hasValidBaseURL || store.connection == .testing || store.isAuthorizing
                          || (store.provider.kind == .openAI && !store.isChatGPTConnected))
            } footer: {
                if case let .failed(message) = store.connection {
                    Text(message)
                }
            }

            if !store.isNew {
                Section {
                    Button("Delete Provider", role: .destructive) {
                        store.send(.deleteTapped)
                    }
                }
            }
        }
        .navigationTitle(store.isNew ? "New Provider" : store.provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    store.send(.saveTapped)
                }
                .disabled(!store.canSave)
            }
        }
        .task { await store.send(.task).finish() }
        .alert("You’re using your ChatGPT plan", isPresented: $store.showPlanNotice) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible requests in Hestrel use your ChatGPT plan. You can manage usage and app access in ChatGPT settings.")
        }
    }

    private var chatGPTSection: some View {
        Section {
            if store.isChatGPTConnected {
                LabeledContent("Connected", value: store.chatGPTEmail ?? "ChatGPT account")
                Label("Using ChatGPT plan", systemImage: "checkmark.circle")
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Button("Sign Out", role: .destructive) { store.send(.disconnectChatGPTTapped) }
                    .disabled(store.isAuthorizing)
            } else {
                Button { store.send(.connectChatGPTTapped) } label: {
                    HStack {
                        Text("Continue with ChatGPT")
                        Spacer()
                        if store.isAuthorizing { ProgressView() }
                    }
                }
                .disabled(store.isAuthorizing)
            }
        } header: {
            Text("ChatGPT Account")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Use your eligible ChatGPT plan in Hestrel. Your connection is stored securely on this device.")
                if let error = store.authError { Text(error).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch store.connection {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case let .succeeded(modelCount):
            Label("\(modelCount) models", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ProviderEditorView(store: Store(
            initialState: ProviderEditorFeature.State(provider: Provider.presets[3], isNew: false)
        ) {
            ProviderEditorFeature()
        })
    }
}
