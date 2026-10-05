import SwiftUI

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(Self.headingFont(level: level))
                .padding(.top, Theme.Spacing.xSmall)

        case let .paragraph(text):
            Text(Self.inline(text))
                .lineSpacing(3)

        case let .code(language, code):
            CodeBlockView(language: language, code: code)

        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(item.marker)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(Self.inline(item.text))
                            .lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }

        case let .quote(text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, Theme.Spacing.medium)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.hairline).frame(width: 3)
                }

        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.large, verticalSpacing: Theme.Spacing.small) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell))
                            }
                        }
                    }
                }
                .font(.subheadline)
                .padding(Theme.Spacing.medium)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Color.hairline)
            }

        case .divider:
            Divider()
        }
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        default: .headline
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#Preview {
    ScrollView {
        MarkdownView(text: """
        # Heading
        Some **bold**, *italic* and `inline code` with a [link](https://example.com).

        - First
        - Second
          - Nested

        1. One
        2. Two

        > A quote

        | Name | Value |
        |------|-------|
        | a    | 1     |

        ```swift
        print("Hello")
        ```
        """)
        .padding()
    }
}
