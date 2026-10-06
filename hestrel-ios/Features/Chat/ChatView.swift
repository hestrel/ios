import ComposableArchitecture
import SwiftUI
import UIKit

struct ChatView: View {
    @Bindable var store: StoreOf<ChatFeature>

    @FocusState private var isComposerFocused: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        Group {
            if store.messages.isEmpty, store.kind == .code {
                EmptyCodeView(
                    agent: store.codeAgent,
                    serverName: store.codeServer?.name,
                    onSuggestion: { store.send(.suggestionTapped($0)) },
                    onPairComputer: { store.send(.pairComputerTapped) }
                )
                .onAppear { if store.codeServer == nil { store.send(.setupAppeared) } }
            } else if store.messages.isEmpty {
                EmptyChatView(
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
        .modifier(ResumeMenu(command: store.conversation?.codeSession?.resumeCommand))
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

    /// Whether the next message is the user's (or there is none), making this the end of a reply.
    private func endsReply(_ message: Message) -> Bool {
        guard let index = store.messages.index(id: message.id), index + 1 < store.messages.count else { return true }
        return store.messages[index + 1].role == .user
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                ForEach(store.messages) { message in
                    MessageRow(
                        message: message,
                        isStreaming: message.id == store.streamingMessageID,
                        isLast: message.id == store.messages.last?.id,
                        showsActions: endsReply(message),
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

/// For a code session the agent has started, the title opens a menu to continue it in a terminal on the computer.
private struct ResumeMenu: ViewModifier {
    let command: String?

    func body(content: Content) -> some View {
        if let command {
            content.toolbarTitleMenu {
                Section("Continue on Your Computer") {
                    Button("Copy Resume Command", systemImage: "terminal") {
                        UIPasteboard.general.string = command
                    }
                }
            }
        } else {
            content
        }
    }
}
