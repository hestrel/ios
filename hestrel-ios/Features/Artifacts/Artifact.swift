import Foundation

/// A substantial piece of code or markup the assistant produced, pulled out of a reply.
struct Artifact: Equatable, Identifiable, Sendable {
    let id: String
    let conversationID: Conversation.ID
    let conversationTitle: String
    let language: String?
    let content: String
    let createdAt: Date

    var lineCount: Int {
        content.components(separatedBy: .newlines).count
    }

    var title: String {
        guard let language else { return "Snippet" }
        return Self.languageNames[language.lowercased()] ?? language.capitalized
    }

    /// HTML and SVG artifacts can be rendered, not just read.
    var isPreviewable: Bool {
        ["html", "svg", "xml"].contains(language?.lowercased() ?? "")
            && (content.contains("<html") || content.contains("<svg") || content.contains("<body") || content.contains("<div"))
    }

    var symbol: String {
        switch language?.lowercased() {
        case "html", "svg", "xml": "globe"
        case "markdown", "md": "doc.text"
        case "json", "yaml", "yml", "toml": "curlybraces"
        case "bash", "sh", "zsh", "shell": "terminal"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    private static let languageNames = [
        "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
        "py": "Python", "python": "Python", "swift": "Swift", "html": "HTML", "css": "CSS", "svg": "SVG",
        "json": "JSON", "yaml": "YAML", "yml": "YAML", "sql": "SQL", "sh": "Shell", "bash": "Shell",
        "md": "Markdown", "markdown": "Markdown", "kotlin": "Kotlin", "go": "Go", "rust": "Rust", "rs": "Rust",
        "jsx": "React", "tsx": "React", "java": "Java", "ruby": "Ruby", "rb": "Ruby", "c": "C", "cpp": "C++",
    ]
}

extension Artifact {
    /// Code blocks shorter than this are inline examples rather than artifacts.
    private static let minimumLines = 4

    static func extract(from conversations: some Sequence<Conversation>) -> [Artifact] {
        var artifacts: [Artifact] = []
        for conversation in conversations {
            for message in conversation.messages where message.role == .assistant {
                let blocks = MarkdownParser.parse(message.display.answer)
                for (index, block) in blocks.enumerated() {
                    guard case let .code(language, code) = block,
                          code.components(separatedBy: .newlines).count >= minimumLines
                    else { continue }
                    artifacts.append(Artifact(
                        id: "\(message.id.uuidString)-\(index)",
                        conversationID: conversation.id,
                        conversationTitle: conversation.title,
                        language: language,
                        content: code,
                        createdAt: message.createdAt
                    ))
                }
            }
        }
        return artifacts.sorted { $0.createdAt > $1.createdAt }
    }
}
