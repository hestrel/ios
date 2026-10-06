import SwiftUI

/// A command a coding agent ran, files it edited, or another tool it used, in the same quiet one-line style
/// as tool calls. Expands to the output or the diff.
struct AgentStepView: View {
    let call: ToolCall
    let step: AgentStep
    let isRunning: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .symbolEffect(.pulse, isActive: isRunning)
                    summary
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    } else if call.result?.isError == true {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                details
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surface, in: .rect(cornerRadius: Theme.Radius.medium))
            }
        }
    }

    private var symbol: String {
        switch step {
        case .command: "terminal"
        case .edit: "pencil"
        case let .activity(_, _, symbol): symbol
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch step {
        case let .command(command, summary):
            if let summary {
                label(summary)
            } else {
                Text(command.components(separatedBy: .newlines).first ?? command)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case let .activity(summary, _, _):
            label(summary)
        case let .edit(files):
            label(editTitle(files))
            let added = files.reduce(0) { $0 + $1.stats.added }
            let removed = files.reduce(0) { $0 + $1.stats.removed }
            DiffStats(added: added, removed: removed)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func editTitle(_ files: [AgentStep.FileChange]) -> String {
        guard files.count == 1, let file = files.first else {
            return "\(isRunning ? "Editing" : "Edited") \(files.count) files"
        }
        let verb = switch file.kind {
        case .add: isRunning ? "Creating" : "Created"
        case .delete: isRunning ? "Deleting" : "Deleted"
        case .update: isRunning ? "Editing" : "Edited"
        }
        return "\(verb) \(file.fileName)"
    }

    @ViewBuilder
    private var details: some View {
        switch step {
        case let .command(command, _):
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("$ " + command)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                if let output = call.result?.content.trimmed.nonBlank {
                    Text(output.count > 6_000 ? String(output.prefix(6_000)) + "\n…" : output)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(Theme.Spacing.medium)
        case let .activity(_, detail, _):
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                if let detail {
                    Text(detail)
                        .font(.footnote.weight(.semibold))
                        .textSelection(.enabled)
                }
                if let output = call.result?.content.trimmed.nonBlank {
                    Text(output.count > 6_000 ? String(output.prefix(6_000)) + "\n…" : output)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if detail == nil {
                    Text(isRunning ? "Working…" : "No output")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.medium)
        case let .edit(files):
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        Text(file.path)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        DiffText(change: file)
                    }
                }
                if call.result?.isError == true, let error = call.result?.content.nonBlank {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.medium)
        }
    }
}

private struct DiffStats: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            if added > 0 { Text("+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }
}

/// A unified diff with added lines in green and removed lines in red.
private struct DiffText: View {
    let change: AgentStep.FileChange

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.background)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .fixedSize(horizontal: true, vertical: false)
        }
        .textSelection(.enabled)
    }

    private struct Line {
        let text: String
        let color: Color
        let background: Color
    }

    /// The first 400 lines; anything longer is better read on the computer.
    private var lines: [Line] {
        let raw = change.diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400).map(String.init)
        return raw.map { text in
            switch change.kind {
            case .add: return Line(text: "+" + text, color: .green, background: .green.opacity(0.08))
            case .delete: return Line(text: "-" + text, color: .red, background: .red.opacity(0.08))
            case .update:
                if text.hasPrefix("@@") { return Line(text: text, color: .secondary, background: .clear) }
                if text.hasPrefix("+") { return Line(text: text, color: .green, background: .green.opacity(0.08)) }
                if text.hasPrefix("-") { return Line(text: text, color: .red, background: .red.opacity(0.08)) }
                return Line(text: text, color: .primary, background: .clear)
            }
        }
    }
}
