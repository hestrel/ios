import SwiftUI

/// The start of a code session: what to ask the agent, or how to connect one when no computer offers it yet.
struct EmptyCodeView: View {
    let agent: CodeAgent
    /// The MCP server running the agent; `nil` until one is connected.
    let serverName: String?
    let onSuggestion: (String) -> Void
    let onPairComputer: () -> Void

    var body: some View {
        if let serverName {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32, weight: .light))
                    Text("What should \(agent.title) do?")
                        .font(.title2.weight(.semibold))
                    Label("\(agent.title) on \(serverName)", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SuggestionStrip(suggestions: Suggestion.code, onSelect: onSuggestion)
            }
        } else {
            ScrollView {
                setup
                    .padding(.horizontal, Theme.Spacing.xLarge)
                    .padding(.vertical, 40)
                    .frame(maxWidth: Theme.maxContentWidth)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.center, for: .alignment)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Image(systemName: "terminal")
                    .font(.system(size: 32, weight: .light))
                Text("Code on Your Computer")
                    .font(.title2.weight(.semibold))
                Text("Code sessions run the coding agents on your computer (Codex, Claude Code, OpenCode, pi and more) in your own projects, with your own accounts. Pair it once and use it from anywhere.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("1. On the computer, run Hestrel’s bridge from your projects folder.")
                CodeBlockView(language: "Terminal", code: Self.bridgeCommand)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("2. Scan the QR code it shows.")
                Button("Pair a Computer", systemImage: "qrcode.viewfinder", action: onPairComputer)
                    .buttonStyle(.glassProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(.systemBackground))
            }

            Label("The computer connects out to Hestrel, so nothing on it is exposed to the internet. Only devices signed in to your account can reach it.", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static let bridgeCommand = "node /path/to/hestrel-ios/Tools/hestrel-bridge.mjs"
}
