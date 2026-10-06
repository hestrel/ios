import ComposableArchitecture
import SwiftUI

/// The Google section of Plugins: one row per service, plus the connected account.
struct ConnectionsView: View {
    let store: StoreOf<ConnectionsFeature>

    var body: some View {
        Section {
            if let email = store.connection.email, store.connection.userID != nil {
                accountRow(email: email)
            }
            ForEach(GoogleService.allCases) { service in
                serviceRow(service)
            }
        } header: {
            HStack(spacing: 6) {
                Image(.googleLogo)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text("Google")
                if store.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } footer: {
            if let error = store.error {
                Text(error)
            } else {
                Text("Read-only. What a plugin retrieves is shared with the model you’re chatting with.")
            }
        }
        .disabled(store.isBusy)
        .task { await store.send(.task).finish() }
    }

    private func accountRow(email: String) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            LogoTile(image: Image(.googleLogo))
            Text(email)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Menu {
                Button("Reconnect", systemImage: "arrow.clockwise") { store.send(.reconnect) }
                Button("Disconnect Google", systemImage: "xmark.circle", role: .destructive) { store.send(.disconnect) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Google account options")
        }
    }

    private func serviceRow(_ service: GoogleService) -> some View {
        let isGranted = store.connection.userID != nil && store.connection.grantedScopes.contains(service.scope)

        return HStack(spacing: Theme.Spacing.medium) {
            LogoTile(image: Image(service.logo))
            VStack(alignment: .leading, spacing: 1) {
                Text(service.title)
                Text(service.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isGranted {
                Toggle(service.title, isOn: Binding(
                    get: { store.connection.isAvailable(service) },
                    set: { store.send(.setEnabled(service, $0)) }
                ))
                .labelsHidden()
                .tint(.toggleTint)
            } else {
                Button("Connect") { store.send(.connect(service)) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Connect \(service.title)")
            }
        }
    }
}
