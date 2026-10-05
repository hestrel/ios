import Foundation

nonisolated enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var marker: String
        var text: String
        var level: Int
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case list([ListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case divider
}

/// A small, forgiving block-level Markdown parser.
///
/// Inline syntax (bold, links, inline code…) is left to `AttributedString(markdown:)`.
/// It tolerates incomplete input, so it can render a response while it is still streaming.
nonisolated struct MarkdownParser {
    private var lines: ArraySlice<String>
    private var blocks: [MarkdownBlock] = []
    private var paragraph: [String] = []
    private var listItems: [MarkdownBlock.ListItem] = []
    private var quote: [String] = []

    static func parse(_ text: String) -> [MarkdownBlock] {
        var parser = MarkdownParser(lines: text.components(separatedBy: .newlines)[...])
        return parser.run()
    }

    private mutating func run() -> [MarkdownBlock] {
        while let line = lines.popFirst() {
            let trimmed = line.trimmed

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                parseCodeBlock(opening: trimmed)
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = Self.heading(in: trimmed) {
                flush()
                blocks.append(heading)
            } else if Self.isDivider(trimmed) {
                flush()
                blocks.append(.divider)
            } else if trimmed.hasPrefix("|"), let next = lines.first, Self.isTableSeparator(next) {
                flush()
                parseTable(header: trimmed)
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(trimmed.dropFirst().trimmed)
            } else if let item = Self.listItem(in: line) {
                flushParagraph()
                flushQuote()
                listItems.append(item)
            } else if !listItems.isEmpty, line.hasPrefix("  ") {
                listItems[listItems.count - 1].text += " " + trimmed
            } else {
                flushList()
                flushQuote()
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    // MARK: Blocks

    private mutating func parseCodeBlock(opening: String) {
        let fence = String(opening.prefix(3))
        let language = opening.dropFirst(3).nonBlank
        var code: [String] = []
        while let line = lines.popFirst(), !line.trimmed.hasPrefix(fence) {
            code.append(line)
        }
        blocks.append(.code(language: language, code: code.joined(separator: "\n")))
    }

    private mutating func parseTable(header: String) {
        lines.removeFirst() // the |---|---| separator
        var rows: [[String]] = []
        while let line = lines.first, line.trimmed.hasPrefix("|") {
            rows.append(Self.cells(in: line))
            lines.removeFirst()
        }
        blocks.append(.table(header: Self.cells(in: header), rows: rows))
    }

    // MARK: Flushing

    private mutating func flush() {
        flushParagraph()
        flushList()
        flushQuote()
    }

    private mutating func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph.removeAll()
    }

    private mutating func flushList() {
        guard !listItems.isEmpty else { return }
        blocks.append(.list(listItems))
        listItems.removeAll()
    }

    private mutating func flushQuote() {
        guard !quote.isEmpty else { return }
        blocks.append(.quote(quote.joined(separator: "\n")))
        quote.removeAll()
    }

    // MARK: Line classification

    private static func heading(in line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmed)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmed
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(in line: String) -> [String] {
        var row = line.trimmed
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map(\.trimmed)
    }

    private static func listItem(in line: String) -> MarkdownBlock.ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        let level = indent / 2

        if let bullet = body.first, "-*+".contains(bullet), body.dropFirst().first == " " {
            let markers = ["•", "◦", "▪︎"]
            return .init(marker: markers[level % markers.count], text: body.dropFirst(2).trimmed, level: level)
        }

        let digits = body.prefix(while: \.isNumber)
        let rest = body.dropFirst(digits.count)
        if (1...3).contains(digits.count), let delimiter = rest.first, ".)".contains(delimiter), rest.dropFirst().first == " " {
            return .init(marker: "\(digits).", text: rest.dropFirst(2).trimmed, level: level)
        }
        return nil
    }
}
