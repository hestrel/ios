import ComposableArchitecture
import SwiftUI

struct ModelSelectionView: View {
    @Bindable var store: StoreOf<ChatFeature>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.isStreaming {
                    Section {
                        Text("Your selection applies to the next message. The current reply continues with its original model.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if store.selectedProvider?.kind.supportsReasoningEffort == true {
                    Section {
                        Picker("Effort", selection: Binding(
                            get: { store.reasoningEffort },
                            set: { store.send(.effortSelected($0)) }
                        )) {
                            ForEach(ReasoningEffort.allCases) { effort in
                                Text(effort.title).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Effort")
                    } footer: {
                        Text("Higher effort thinks longer for harder questions. Auto uses the model’s default.")
                    }
                }
                ForEach(store.providers.filter(\.isEnabled)) { provider in
                    Section(provider.name) {
                        ForEach(store.catalog.models(for: provider.id)) { model in
                            Button {
                                store.send(.modelSelected(model.id))
                            } label: {
                                HStack {
                                    Text(model.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if store.selectedModel?.id == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(store.selectedModel?.id == model.id ? .isSelected : [])
                        }
                        if store.catalog.models(for: provider.id).isEmpty {
                            switch store.catalog.statuses[provider.id] {
                            case .loading:
                                HStack { ProgressView(); Text("Loading models…") }
                            case let .failed(message):
                                Text(message).foregroundStyle(.secondary)
                            case .ready:
                                Text("No models available").foregroundStyle(.secondary)
                            case nil:
                                Text("Models haven’t loaded yet").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if store.selectedModelID != nil && store.selectedModel == nil {
                    Section {
                        Text("Your selected model is unavailable. Choose an available model to continue.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Manage Providers", systemImage: "gearshape") {
                        store.send(.modelPickerManageProvidersTapped)
                    }
                }
            }
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
