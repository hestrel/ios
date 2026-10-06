import SwiftUI

struct EmptyChatView: View {
    let hasModels: Bool
    let onSuggestion: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if hasModels {
                Text("What can I help with?")
                    .font(.title2.weight(.semibold))
            } else {
                onboarding
            }
            Spacer()
            if hasModels {
                SuggestionStrip(suggestions: Suggestion.chat, onSelect: onSuggestion)
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
}

/// Starter prompts in a horizontal row above the composer.
struct SuggestionStrip: View {
    let suggestions: [Suggestion]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelect(suggestion.prompt)
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

struct Suggestion: Identifiable {
    let title: String
    let subtitle: String
    let prompt: String
    var id: String { title }

    static let chat = [
        Suggestion(title: "Explain", subtitle: "how a transformer works", prompt: "Explain how a transformer neural network works, in simple terms."),
        Suggestion(title: "Write", subtitle: "a polite follow-up email", prompt: "Write a short, polite follow-up email to a recruiter I haven't heard back from."),
        Suggestion(title: "Plan", subtitle: "a weekend in Lisbon", prompt: "Plan a relaxed two-day weekend itinerary in Lisbon."),
        Suggestion(title: "Debug", subtitle: "a Swift concurrency error", prompt: "What does \"Sending value risks causing data races\" mean in Swift 6, and how do I fix it?"),
    ]

    static let code = [
        Suggestion(title: "Explain", subtitle: "how this project is organized", prompt: "Give me a short tour of this project: what it does, how it's organized, and where to start reading."),
        Suggestion(title: "Review", subtitle: "my uncommitted changes", prompt: "Review my uncommitted changes. Point out bugs and anything that looks unfinished. Don't change any files."),
        Suggestion(title: "Fix", subtitle: "the failing tests", prompt: "Run the tests, find out why any are failing, and fix them."),
        Suggestion(title: "Find", subtitle: "TODOs worth doing", prompt: "Find the TODO and FIXME comments in this project and suggest which three are most worth doing."),
    ]
}
