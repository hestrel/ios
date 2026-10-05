import ComposableArchitecture
import SwiftUI

struct ChatView: View {
    @Bindable var store: StoreOf<ChatFeature>

    @FocusState private var isComposerFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        Group {
            if store.messages.isEmpty {
                EmptyChatView(
                    kind: store.kind,
                    hasModels: !store.modelGroups.isEmpty,
                    onSuggestion: { store.send(.suggestionTapped($0)) },
                    onOpenSettings: { store.send(.openSettingsTapped) }
                )
            } else {
                messageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            ComposerView(store: store, isFocused: $isComposerFocused)
        }

        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert($store.scope(state: \.alert, action: \.alert))
        .sensoryFeedback(.impact(weight: .light), trigger: store.messages.count)
        .onChange(of: store.conversationID) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private var title: String {
        if let conversation = store.conversation {
            return conversation.title
        }
        return store.kind == .code ? "New Code Session" : ""
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                ForEach(store.messages) { message in
                    MessageRow(
                        message: message,
                        isStreaming: message.id == store.streamingMessageID,
                        isLast: message.id == store.messages.last?.id,
                        onRegenerate: { store.send(.regenerateTapped) }
                    )
                    .id(message.id)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.large)
            .frame(maxWidth: Theme.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: store.messages.count) {
            withAnimation { scrollPosition.scrollTo(edge: .bottom) }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(store: Store(initialState: ChatFeature.State()) {
            ChatFeature()
        })
    }
}
