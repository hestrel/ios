import ComposableArchitecture
import SwiftUI

struct ArtifactsView: View {
    @Bindable var store: StoreOf<ArtifactsFeature>

    var body: some View {
        let artifacts = store.artifacts

        List(artifacts) { artifact in
            Button {
                store.send(.artifactTapped(artifact))
            } label: {
                ArtifactRow(artifact: artifact)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .overlay {
            if artifacts.isEmpty {
                if store.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Artifacts Yet",
                        systemImage: "square.on.square",
                        description: Text("Code, documents and web pages created in your chats appear here.")
                    )
                } else {
                    ContentUnavailableView.search(text: store.searchText)
                }
            }
        }
        .searchable(text: $store.searchText, prompt: "Search artifacts")
        .navigationTitle("Artifacts")
    }
}

private struct ArtifactRow: View {
    let artifact: Artifact

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: artifact.symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background(Color.fill, in: .rect(cornerRadius: Theme.Radius.small))
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.conversationTitle)
                    .lineLimit(1)
                Text("\(artifact.title) · ^[\(artifact.lineCount) line](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}
