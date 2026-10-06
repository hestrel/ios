import ComposableArchitecture
import SwiftUI

struct PairComputerView: View {
    @Bindable var store: StoreOf<PairComputerFeature>

    var body: some View {
        NavigationStack {
            Group {
                if store.account == nil {
                    signInPrompt
                } else if case let .paired(name) = store.status {
                    paired(name)
                } else {
                    pairing
                }
            }
            .navigationTitle("Pair a Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.doneTapped) }
                }
            }
        }
        .task { await store.send(.task).finish() }
        .sensoryFeedback(.success, trigger: store.status) { _, status in
            if case .paired = status { return true }
            return false
        }
    }

    private var pairing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                Text("On your computer, run Hestrel’s bridge from your projects folder, then scan the code it shows.")
                    .foregroundStyle(.secondary)
                CodeBlockView(language: "Terminal", code: EmptyCodeView.bridgeCommand)

                if QRScannerView.isAvailable {
                    QRScannerView { store.send(.codeScanned($0)) }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: Theme.Radius.medium))
                        .overlay {
                            if store.status == .pairing {
                                ProgressView("Pairing…")
                                    .padding()
                                    .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.small))
                            }
                        }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(QRScannerView.isAvailable ? "Or enter the code" : "Enter the code shown on the computer")
                        .font(.subheadline.weight(.medium))
                    HStack {
                        TextField("XXXX-XXXX", text: $store.typedCode)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { store.send(.submitTapped) }
                            .padding(Theme.Spacing.medium)
                            .background(Color.surface, in: .rect(cornerRadius: Theme.Radius.small))
                        Button("Pair") { store.send(.submitTapped) }
                            .buttonStyle(.glassProminent)
                            .tint(.primary)
                            .foregroundStyle(Color(.systemBackground))
                            .disabled(!store.canSubmit)
                    }
                }

                if case let .failed(message) = store.status {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }

                Label("The computer is linked to your Hestrel account, so all your devices can use it, from anywhere.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.large)
        }
    }

    private func paired(_ name: String) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
            Text("\(name) is paired")
                .font(.title2.weight(.semibold))
            Text("Its coding agents are ready in the Code tab on every device signed in to your account.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { store.send(.doneTapped) }
                .buttonStyle(.glassProminent)
                .tint(.primary)
                .foregroundStyle(Color(.systemBackground))
                .padding(.top, Theme.Spacing.small)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signInPrompt: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 44, weight: .light))
            Text("Sign In First")
                .font(.title2.weight(.semibold))
            Text("Paired computers belong to your Hestrel account, so every device signed in to it can use them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Sign In") { store.send(.signInTapped) }
                .buttonStyle(.glassProminent)
                .tint(.primary)
                .foregroundStyle(Color(.systemBackground))
                .padding(.top, Theme.Spacing.small)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
