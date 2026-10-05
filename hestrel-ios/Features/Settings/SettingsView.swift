import AuthenticationServices
import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
    @Bindable var store: StoreOf<SettingsFeature>

    @Environment(\.colorScheme) private var colorScheme
    /// Hashed into the Sign in with Apple request, so an intercepted identity token can't be replayed.
    @State private var signInNonce = AppleCredential.makeNonce()

    var body: some View {
        NavigationStack(path: $store.path) {
            Form {
                Section {
                    NavigationLink(value: SettingsFeature.Page.account) {
                        HStack(spacing: 12) {
                            AccountAvatar(email: store.account?.email)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Account")
                                    .font(.headline)
                                Text(store.account?.email ?? (store.account == nil ? "Sign in to sync your chats" : "Apple Account"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Setup") {
                    pageLink(.providers, symbol: "cpu", detail: "\(store.providers.count)")
                    Button { store.send(.openPluginsTapped) } label: {
                        HStack {
                            Label("Plugins", systemImage: "puzzlepiece.extension")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                Section("Preferences") {
                    pageLink(.instructions, symbol: "text.bubble")
                    pageLink(.data, symbol: "externaldrive")
                }
                Section {
                    pageLink(.about, symbol: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { doneButton }
            .navigationDestination(for: SettingsFeature.Page.self) { page in
                self.page(page)
            }
            .alert($store.scope(state: \.destination?.alert, action: \.destination.alert))
        }
    }

    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark") {
                store.send(.doneTapped)
            }
        }
    }

    private func pageLink(_ page: SettingsFeature.Page, symbol: String, detail: String? = nil) -> some View {
        NavigationLink(value: page) {
            HStack {
                Label(page.title, systemImage: symbol)
                Spacer()
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func page(_ page: SettingsFeature.Page) -> some View {
        Form {
            switch page {
            case .account: accountSection
            case .providers: providersSection
            case .instructions: instructionsSection
            case .data: dataSection
            case .about: aboutSection
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { doneButton }
        .navigationDestination(
            item: $store.scope(state: \.destination?.providerEditor, action: \.destination.providerEditor)
        ) { editorStore in
            ProviderEditorView(store: editorStore)
        }
    }

    private var accountSection: some View {
        Section {
            if let account = store.account {
                LabeledContent("Signed In", value: account.email ?? "Apple Account")
                LabeledContent("Last Synced") {
                    if store.syncStatus.isSyncing {
                        ProgressView()
                    } else if let lastSyncedAt = store.syncStatus.lastSyncedAt {
                        Text(lastSyncedAt, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    store.send(.syncNowTapped)
                }
                .disabled(store.syncStatus.isSyncing)
                Button("Sign Out") {
                    store.send(.signOutTapped)
                }
                Button("Delete Account", role: .destructive) {
                    store.send(.deleteAccountTapped)
                }
                .disabled(store.syncStatus.isDeletingAccount)
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                    request.nonce = AppleCredential.hashed(signInNonce)
                } onCompletion: { result in
                    switch result {
                    case let .success(authorization):
                        if let credential = AppleCredential(authorization: authorization, nonce: signInNonce) {
                            store.send(.signInWithAppleCompleted(credential))
                        } else {
                            store.send(.signInWithAppleFailed(AppleSignInError.missingCredential.localizedDescription))
                        }
                    case let .failure(error):
                        if !error.isAppleSignInCancellation {
                            store.send(.signInWithAppleFailed(error.localizedDescription))
                        }
                    }
                    signInNonce = AppleCredential.makeNonce()
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 44)
                .disabled(store.syncStatus.isSigningIn)
            }
        } header: {
            Text("Account")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = store.syncStatus.errorDescription {
                    Text(error).foregroundStyle(.red)
                }
                Text(store.account == nil
                    ? "Sign in to sync your providers and chats across devices. API keys and sign-ins never leave this device."
                    : "Providers and chats sync across your devices. API keys and sign-ins never leave this device.")
            }
        }
    }

    private var providersSection: some View {
        Section {
            ForEach(store.providers) { provider in
                Button {
                    store.send(.providerTapped(provider.id))
                } label: {
                    ProviderRow(
                        provider: provider,
                        status: store.catalog.statuses[provider.id],
                        modelCount: store.catalog.models(for: provider.id).count
                    )
                }
                .buttonStyle(.plain)
                .deleteSwipeAction { store.send(.providerDeleted(provider.id)) }
            }

            Menu {
                ForEach(ProviderKind.allCases) { kind in
                    Button(kind.displayName, systemImage: kind.symbol) {
                        store.send(.addProviderTapped(kind))
                    }
                }
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Provider credentials are stored securely on this device.")
        }
    }

    private var instructionsSection: some View {
        Section {
            TextField(
                "How would you like the assistant to respond?",
                text: Binding(store.$systemPrompt),
                axis: .vertical
            )
            .lineLimit(3...8)
        } header: {
            Text("Custom Instructions")
        } footer: {
            Text("Sent as the system prompt with every conversation.")
        }
    }

    private var dataSection: some View {
        Section {
            LabeledContent("Chats", value: "\(store.conversations.count)")
            Button("Delete All Chats", role: .destructive) {
                store.send(.deleteAllChatsTapped)
            }
            .disabled(store.conversations.isEmpty)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.appVersion)
        }
    }
}

private struct ProviderRow: View {
    let provider: Provider
    let status: LoadStatus?
    let modelCount: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: provider.kind.symbol)
                .font(.body.weight(.medium))
                .frame(width: 32, height: 32)
                .background(Color.fill, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            trailing
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private var subtitle: String {
        if case let .failed(message) = status, provider.isEnabled {
            return message
        }
        return provider.kind.displayName
    }

    @ViewBuilder
    private var trailing: some View {
        if !provider.isEnabled {
            Text("Off")
        } else {
            switch status {
            case .loading:
                ProgressView()
            case .ready:
                Text("^[\(modelCount) model](inflect: true)")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
            case nil:
                EmptyView()
            }
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView(store: Store(initialState: SettingsFeature.State()) {
        SettingsFeature()
    })
}
