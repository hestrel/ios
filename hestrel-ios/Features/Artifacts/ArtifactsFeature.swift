import ComposableArchitecture
import Foundation

/// A gallery of every artifact across all conversations.
@Reducer
struct ArtifactsFeature {
    @ObservableState
    struct State: Equatable {
        var searchText = ""
        @Shared(.conversations) var conversations: IdentifiedArrayOf<Conversation>

        var artifacts: [Artifact] {
            let all = Artifact.extract(from: conversations)
            guard let query = searchText.nonBlank else { return all }
            return all.filter {
                $0.conversationTitle.localizedStandardContains(query)
                    || $0.title.localizedStandardContains(query)
                    || $0.content.localizedStandardContains(query)
            }
        }
    }

    enum Action: BindableAction {
        case artifactTapped(Artifact)
        case binding(BindingAction<State>)
        case delegate(Delegate)

        enum Delegate: Equatable {
            case artifactSelected(Artifact)
        }
    }

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { _, action in
            switch action {
            case let .artifactTapped(artifact):
                return .send(.delegate(.artifactSelected(artifact)))
            case .binding, .delegate:
                return .none
            }
        }
    }
}
