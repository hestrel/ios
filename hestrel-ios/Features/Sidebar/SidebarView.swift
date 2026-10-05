import ComposableArchitecture
import SwiftUI

struct SidebarView: View {
    @Bindable var store: StoreOf<SidebarFeature>

    /// Rows inset their content past the selection highlight so it has room on both sides.
    private static let highlightInset = Theme.Spacing.medium
    private static let rowInsets = EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24)

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                Section {
                    ForEach(SidebarFeature.Destination.allCases, id: \.self) { destination in
                        menuRow(destination)
                    }
                }
                // Kept out of the Recents section: swapping it for the last chat mid-animation confuses the List.
                if store.recents.isEmpty {
                    Section {
                        Text("Your chats will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowInsets(Self.rowInsets)
                    }
                }
                Section {
                    ForEach(store.recents) { conversation in
                        row(for: conversation)
                    }
                } header: {
                    Text("Recents")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        // Section headers sit at the list's default 16pt inset; line up with the rows.
                        .padding(.leading, Self.rowInsets.leading - 16)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    store.send(.accountTapped)
                } label: {
                    AccountAvatar(email: store.account?.email)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Account settings")
                .accessibilityValue(store.account?.email ?? (store.account == nil ? "Signed out" : "Signed in"))
                Spacer()
                newChatButton
            }
            .padding(.horizontal, Self.rowInsets.leading)
            .padding(.vertical, Theme.Spacing.small)
            .background(Color(.systemBackground))
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .alert($store.scope(state: \.alert, action: \.alert))
        .alert("Rename Chat", isPresented: isRenaming) {
            TextField("Title", text: $store.renameDraft)
            Button("Cancel", role: .cancel) { store.send(.renameCancelled) }
            Button("Save") { store.send(.renameConfirmed) }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            HestrelGlyph()
                .frame(width: 18, height: 21)
                .accessibilityHidden(true)
            Text("Hestrel")
                .font(.title2.bold())
            Spacer()
            Button("Settings", systemImage: "gearshape") {
                store.send(.settingsTapped)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.leading, Self.rowInsets.leading)
        .padding(.trailing, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }

    private func menuRow(_ destination: SidebarFeature.Destination) -> some View {
        Button {
            store.send(.destinationTapped(destination))
        } label: {
            Label(destination.title, systemImage: destination.symbol)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(Self.rowInsets)
        .listRowBackground(selectionBackground(isSelected: store.activeDestination == destination))
    }

    private func row(for conversation: Conversation) -> some View {
        let isSelected = store.activeDestination == nil && conversation.id == store.selectedConversationID

        return Button {
            store.send(.conversationTapped(conversation.id))
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                if conversation.kind == .code {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(conversation.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if store.respondingConversationIDs.contains(conversation.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Generating a reply")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(Self.rowInsets)
        .listRowBackground(selectionBackground(isSelected: isSelected))
        .deleteSwipeAction { store.send(.deleteTapped(conversation.id)) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                store.send(.renameTapped(conversation.id))
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                store.send(.deleteTapped(conversation.id))
            }
        }
    }

    private func selectionBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.small)
            .fill(isSelected ? Color.fill : .clear)
            .padding(.horizontal, Self.highlightInset)
    }

    private var newChatButton: some View {
        Button {
            store.send(.newChatTapped)
        } label: {
            Label("New chat", systemImage: "plus")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(.primary)
        .foregroundStyle(Color(.systemBackground))
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { store.renamingConversationID != nil },
            set: { if !$0 { store.send(.renameCancelled) } }
        )
    }
}

#Preview {
    SidebarView(store: Store(initialState: SidebarFeature.State()) {
        SidebarFeature()
    })
}
