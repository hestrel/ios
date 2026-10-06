import ComposableArchitecture
import SwiftUI

/// The agent, model and effort for a new code session.
struct CodeSettingsView: View {
    @Bindable var store: StoreOf<ChatFeature>
    @Environment(\.dismiss) private var dismiss
    @State private var modelSearch = ""

    var body: some View {
        NavigationStack {
            List {
                if store.availableCodeAgents.count > 1 {
                    Section("Agent") {
                        ForEach(store.availableCodeAgents) { agent in
                            row(title: agent.title, subtitle: nil, isSelected: store.codeAgent == agent) {
                                modelSearch = ""
                                store.send(.codeAgentSelected(agent))
                            }
                        }
                    }
                }

                if store.codeAgent.supportsEffort {
                    Section {
                        Picker("Effort", selection: Binding(
                            get: { store.codeEffort },
                            set: { store.send(.codeEffortSelected($0)) }
                        )) {
                            ForEach(ReasoningEffort.allCases) { effort in
                                Text(effort.title).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Effort")
                    } footer: {
                        Text("Higher effort thinks longer on harder tasks. Auto uses \(store.codeAgent.title)’s default.")
                    }
                }

                Section {
                    if store.codeModels.count > 12 {
                        SearchField(prompt: "Search \(store.codeModels.count) models", text: $modelSearch)
                    }
                    row(title: "Default", subtitle: store.codeAgent.defaultModelDescription, isSelected: store.codeModel == nil) {
                        store.send(.codeModelSelected(nil))
                    }
                    ForEach(filteredModels) { model in
                        row(title: model.title, subtitle: nil, isSelected: store.codeModel == model.id) {
                            store.send(.codeModelSelected(model.id))
                        }
                    }
                    if store.loadingModelsFor == store.codeAgent.id {
                        HStack { ProgressView(); Text("Loading models…").foregroundStyle(.secondary) }
                    }
                    if let custom = store.codeModel, !store.codeModels.contains(where: { $0.id == custom }) {
                        row(title: custom, subtitle: "Not in the list right now", isSelected: true) {}
                    }
                } header: {
                    Text("Model")
                } footer: {
                    modelFooter
                }

                if store.codeAgent.kind == .codex && store.codeModels.isEmpty {
                    Section {
                        Button("Manage Providers", systemImage: "gearshape") {
                            store.send(.modelPickerManageProvidersTapped)
                        }
                    }
                }
            }
            .navigationTitle("Code Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { store.send(.codeSettingsAppeared) }
        }
    }

    private var filteredModels: [CodeModel] {
        let query = modelSearch.trimmed
        guard !query.isEmpty else { return store.codeModels }
        return store.codeModels.filter { $0.title.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
    }

    @ViewBuilder
    private var modelFooter: some View {
        switch store.codeAgent.kind {
        case .codex where store.codeModels.isEmpty:
            Text("Sign in with ChatGPT in Settings to choose from your account’s models.")
        case .codex:
            Text("Models from your ChatGPT account, which Codex also uses.")
        case .claudeCode:
            Text("Each name picks the latest model of that family, on your Claude Code account.")
        case .harness:
            Text("Models \(store.codeAgent.title) can use with the accounts set up on your computer.")
        }
    }

    private func row(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.primary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
