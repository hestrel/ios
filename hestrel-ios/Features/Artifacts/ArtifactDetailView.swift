import ComposableArchitecture
import SwiftUI
import WebKit

struct ArtifactDetailView: View {
    @Bindable var store: StoreOf<ArtifactDetailFeature>

    var body: some View {
        Group {
            switch store.mode {
            case .preview:
                ArtifactPreview(html: store.artifact.content)
            case .code:
                ScrollView([.horizontal, .vertical]) {
                    Text(store.artifact.content)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.surface)
            }
        }
        .navigationTitle(store.artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.artifact.isPreviewable {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $store.mode) {
                        Text("Preview").tag(ArtifactDetailFeature.Mode.preview)
                        Text("Code").tag(ArtifactDetailFeature.Mode.code)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                CopyButton(text: store.artifact.content, title: "Copy")
                Spacer()
                ShareLink(item: store.artifact.content)
                Spacer()
                Button("Open Chat", systemImage: "bubble.left") {
                    store.send(.openConversationTapped)
                }
            }
        }
    }
}

/// Renders HTML or SVG artifacts in a web view.
private struct ArtifactPreview: View {
    let html: String
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .task(id: html) {
                page.load(html: Self.mobileFriendly(html), baseURL: URL(string: "about:blank")!)
            }
    }

    /// Model-written pages often omit the viewport tag, which makes WebKit render them at desktop width.
    private static func mobileFriendly(_ html: String) -> String {
        guard !html.contains("name=\"viewport\"") else { return html }
        return #"<meta name="viewport" content="width=device-width, initial-scale=1">"# + html
    }
}
