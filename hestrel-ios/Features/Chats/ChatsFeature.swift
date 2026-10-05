import ComposableArchitecture
import Foundation

/// The full, searchable list of conversations.
@Reducer
struct ChatsFeature {
    @ObservableState
    struct State: Equatable {
        var searchText = ""
        @Presents var alert: AlertState<Action.Alert>?
        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>
    }

    enum Action: BindableAction {
        case alert(PresentationAction<Alert>)
        case binding(BindingAction<State>)
        case conversationTapped(Conversation.ID)
        case delegate(Delegate)
        case deleteTapped(Conversation.ID)

        enum Alert: Equatable {
            case confirmDelete(Conversation.ID)
        }

        enum Delegate: Equatable {
            case conversationDeleted(Conversation.ID)
            case conversationSelected(Conversation.ID)
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
                return .merge(
                    .run { [attachments] _ in attachments.delete(attachments: images) },
                    .send(.delegate(.conversationDeleted(id)))
                )

            case .alert, .binding, .delegate:
                return .none

            case let .conversationTapped(id):
                return .send(.delegate(.conversationSelected(id)))

            case let .deleteTapped(id):
                guard let conversation = state.conversations[id: id] else { return .none }
                state.alert = .confirmDelete(conversation, action: .confirmDelete(id))
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }
}
