import ComposableArchitecture
import Foundation

@Reducer
struct SidebarFeature {
    enum Destination: Equatable, CaseIterable {
        case chats
        case code
        case artifacts
        case plugins
    }

    @ObservableState
    struct State: Equatable {
        var selectedConversationID: Conversation.ID?
        /// Chats with a reply still being generated.
        var respondingConversationIDs: Set<Conversation.ID> = []
        /// The menu item whose view is showing; `nil` while a conversation is open.
        var activeDestination: Destination?
        var renamingConversationID: Conversation.ID?
        var renameDraft = ""
        @Presents var alert: AlertState<Action.Alert>?
        @Shared(.account) var account: Account?
        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>

        var recents: [Conversation] {
            conversations.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    enum Action: BindableAction {
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case conversationTapped(Conversation.ID)
        case delegate(Delegate)
        case deleteTapped(Conversation.ID)
        case destinationTapped(Destination)
        case newChatTapped
        case renameCancelled
        case renameConfirmed
        case renameTapped(Conversation.ID)
        case accountTapped
        case settingsTapped

        enum Alert: Equatable {
            case confirmDelete(Conversation.ID)
        }

        enum Delegate: Equatable {
            case conversationDeleted(Conversation.ID)
            case conversationSelected(Conversation.ID)
            case destinationSelected(Destination)
            case newChat
            case openAccount
            case openSettings
        }
    }

    @Dependency(\.attachments) var attachments

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case let .alert(.presented(.confirmDelete(id))):
                let images = state.conversations[id: id]?.messages.flatMap(\.attachments) ?? []
                state.$conversations.withLock { _ = $0.remove(id: id) }
                if state.selectedConversationID == id {
                    state.selectedConversationID = nil
                }
                return .merge(
                    .run { [attachments] _ in attachments.delete(attachments: images) },
                    .send(.delegate(.conversationDeleted(id)))
                )

            case .alert, .binding, .delegate:
                return .none

            case let .conversationTapped(id):
                state.selectedConversationID = id
                return .send(.delegate(.conversationSelected(id)))

            case let .deleteTapped(id):
                guard let conversation = state.conversations[id: id] else { return .none }
                state.alert = .confirmDelete(conversation, action: .confirmDelete(id))
                return .none

            case let .destinationTapped(destination):
                return .send(.delegate(.destinationSelected(destination)))

            case .newChatTapped:
                state.selectedConversationID = nil
                return .send(.delegate(.newChat))

            case .renameCancelled:
                state.renamingConversationID = nil
                return .none

            case .renameConfirmed:
                if let id = state.renamingConversationID, let title = state.renameDraft.nonBlank {
                    state.$conversations.withLock { $0[id: id]?.title = title }
                }
                state.renamingConversationID = nil
                return .none

            case let .renameTapped(id):
                state.renamingConversationID = id
                state.renameDraft = state.conversations[id: id]?.title ?? ""
                return .none

            case .accountTapped:
                return .send(.delegate(.openAccount))

            case .settingsTapped:
                return .send(.delegate(.openSettings))
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}

extension SidebarFeature.Destination {
    var title: String {
        switch self {
        case .chats: "Chats"
        case .code: "Code"
        case .artifacts: "Artifacts"
        case .plugins: "Plugins"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .artifacts: "square.on.square"
        case .plugins: "puzzlepiece.extension"
        }
    }
}
