import ComposableArchitecture
import SwiftUI

struct ChatsView: View {
    @Bindable var store: StoreOf<ChatsFeature>

    var body: some View {
        let sections = ConversationSection.make(
            from: store.conversations,
            matching: store.searchText,
            now: .now
        )

        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.conversations) { conversation in
                        Button {
                            store.send(.conversationTapped(conversation.id))
                        } label: {
                            row(for: conversation)
                        }
                        .buttonStyle(.plain)
                        .deleteSwipeAction { store.send(.deleteTapped(conversation.id)) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if sections.isEmpty {
                if store.searchText.isEmpty {
                    ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right", description: Text("Start a conversation and it will show up here."))
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search chats")
        .navigationTitle("Chats")
        .alert($store.scope(state: \.alert, action: \.alert))
    }

    private func row(for conversation: Conversation) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: conversation.kind == .code ? "chevron.left.forwardslash.chevron.right" : "bubble.left")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .lineLimit(1)
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
