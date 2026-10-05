import SwiftUI

struct EmptyChatView: View {
    let kind: Conversation.Kind
    let hasModels: Bool
    let onSuggestion: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if hasModels {
                VStack(spacing: Theme.Spacing.medium) {
                    if kind == .code {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 32, weight: .light))
                    }
                    Text(kind == .code ? "What are we building?" : "What can I help with?")
                        .font(.title2.weight(.semibold))
                }
            } else {
                onboarding
            }
            Spacer()
            if hasModels {
                suggestions
            }
        }
    }

    private var onboarding: some View {
        VStack(spacing: Theme.Spacing.large) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 44, weight: .light))
            VStack(spacing: Theme.Spacing.small) {
                Text("Connect a Model")
                    .font(.title2.weight(.semibold))
                Text("Sign in with ChatGPT, add an Anthropic or Gemini API key, or point Hestrel at an Ollama server.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.glassProminent)
                .tint(.primary)
                .foregroundStyle(Color(.systemBackground))
        }
        .padding(.horizontal, 40)
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(Suggestion.all(for: kind)) { suggestion in
                    Button {
                        onSuggestion(suggestion.prompt)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline.weight(.semibold))
                            Text(suggestion.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, Theme.Spacing.large)
                        .padding(.vertical, Theme.Spacing.medium)
                        .background(Color.surface, in: .rect(cornerRadius: Theme.Radius.medium))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.large)
        }
        .scrollClipDisabled()
        .padding(.bottom, Theme.Spacing.medium)
    }
}

private struct Suggestion: Identifiable {
    let title: String
    let subtitle: String
    let prompt: String
    var id: String { title }

    static func all(for kind: Conversation.Kind) -> [Suggestion] {
        switch kind {
        case .chat:
            [
                Suggestion(title: "Explain", subtitle: "how a transformer works", prompt: "Explain how a transformer neural network works, in simple terms."),
                Suggestion(title: "Write", subtitle: "a polite follow-up email", prompt: "Write a short, polite follow-up email to a recruiter I haven't heard back from."),
                Suggestion(title: "Plan", subtitle: "a weekend in Lisbon", prompt: "Plan a relaxed two-day weekend itinerary in Lisbon."),
                Suggestion(title: "Debug", subtitle: "a Swift concurrency error", prompt: "What does \"Sending value risks causing data races\" mean in Swift 6, and how do I fix it?"),
            ]
        case .code:
            [
                Suggestion(title: "Build", subtitle: "a landing page in HTML", prompt: "Build a single-file, responsive landing page in HTML and CSS for a minimalist note-taking app."),
                Suggestion(title: "Write", subtitle: "a SwiftUI view", prompt: "Write a SwiftUI view that shows a searchable list of contacts with sections by first letter."),
                Suggestion(title: "Refactor", subtitle: "callbacks to async/await", prompt: "Show how to refactor a completion-handler based networking function to async/await in Swift."),
                Suggestion(title: "Script", subtitle: "a file renamer in Python", prompt: "Write a Python script that renames photos in a folder by their EXIF date."),
            ]
        }
    }
}
