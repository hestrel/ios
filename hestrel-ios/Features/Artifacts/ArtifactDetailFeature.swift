import ComposableArchitecture
import Foundation

@Reducer
struct ArtifactDetailFeature {
    nonisolated enum Mode: Equatable, Hashable, Sendable {
        case preview
        case code
    }

    @ObservableState
    struct State: Equatable {
        let artifact: Artifact
        var mode: Mode

        init(artifact: Artifact) {
            self.artifact = artifact
            mode = artifact.isPreviewable ? .preview : .code
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case openConversationTapped

        enum Delegate: Equatable {
            case openConversation(Conversation.ID)
        }
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding, .delegate:
                return .none
            case .openConversationTapped:
                return .send(.delegate(.openConversation(state.artifact.conversationID)))
            }
        }
    }
}
