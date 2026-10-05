import SwiftUI
import UIKit

/// Copies text to the pasteboard and briefly confirms with a checkmark.
struct CopyButton: View {
    let text: String
    var title: String?

    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            didCopy = true
        } label: {
            let icon = didCopy ? "checkmark" : "doc.on.doc"
            Group {
                if let title {
                    Label(didCopy ? "Copied" : title, systemImage: icon)
                } else {
                    Image(systemName: icon)
                        .accessibilityLabel("Copy")
                }
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: didCopy) { _, copied in copied }
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
