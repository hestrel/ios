import SwiftUI
import UIKit

struct MessageRow: View {
    let message: Message
    let isStreaming: Bool
    let isLast: Bool
    let onRegenerate: () -> Void

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantReply
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
            if !message.attachments.isEmpty {
                HStack(spacing: Theme.Spacing.small) {
                    ForEach(message.attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, size: 120)
                    }
                }
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, 10)
                    .background(Color.fill, in: .rect(cornerRadius: Theme.Radius.bubble))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.content
                        }
                    }
            }
        }
        .padding(.leading, 56)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantReply: some View {
        let display = message.display

        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if !display.reasoning.isEmpty {
                ReasoningView(
                    reasoning: display.reasoning,
                    isThinking: isStreaming && (display.isReasoningInProgress || display.answer.isEmpty)
                )
            }

            ForEach(message.toolCalls) { call in
                ToolCallView(call: call, isRunning: isStreaming && call.result == nil)
            }

            if !display.answer.isEmpty {
                MarkdownView(text: display.answer)
            } else if isStreaming && display.reasoning.isEmpty && message.toolCalls.isEmpty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 12))
                    .symbolEffect(.breathe)
                    .padding(.vertical, 6)
            }

            if let error = message.errorDescription {
                ErrorBanner(message: error, onRetry: isLast ? onRegenerate : nil)
            }

            if !isStreaming && !display.answer.isEmpty {
                actions(answer: display.answer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(answer: String) -> some View {
        HStack(spacing: Theme.Spacing.large) {
            CopyButton(text: answer)
            if isLast {
                Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
                    .labelStyle(.iconOnly)
            }
            if let modelName = message.modelName {
                Text(modelName)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
    }
}

private struct ReasoningView: View {
    let reasoning: String
    let isThinking: Bool

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(reasoning)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Theme.Spacing.medium)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.hairline).frame(width: 2)
                }
                .padding(.top, Theme.Spacing.small)
        } label: {
            Label(isThinking ? "Thinking…" : "Thought process", systemImage: "brain")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: isThinking)
        }
        .tint(.secondary)
    }
}

private struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
            if let onRetry {
                Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.medium)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.hairline)
        }
    }
}
