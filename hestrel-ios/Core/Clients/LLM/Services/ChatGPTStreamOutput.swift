import Foundation
import OpenAI

/// Match SDK enums directly: their synthesized encoding is not the API wire format.
nonisolated enum ChatGPTStreamOutput {
    /// ChatGPT wraps a citation's span in this private-use character; the span is replaced by the link.
    static let citationMarker = "\u{E200}"

    static var webSearchTool: Tool { .webSearchTool(.init(_type: .webSearch)) }

    static func searchActivity(id: String) -> ToolCall {
        ToolCall(id: id, name: "Web search", arguments: "{}", serverName: "Web", hostedBy: "OpenAI")
    }

    static func toolCall(_ item: OutputItem) -> ToolCall? {
        switch item {
        case let .functionToolCall(call):
            return ToolCall(id: call.callId, name: call.name, arguments: call.arguments)
        case let .webSearchToolCall(call):
            let name: String
            switch call.action {
            case .webSearchActionSearch: name = "Web search"
            case .webSearchActionOpenPage: name = "Open page"
            case .webSearchActionFind: name = "Find in page"
            }
            let arguments = (try? JSONEncoder().encode(call.action)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return ToolCall(id: call.id, name: name, arguments: arguments,
                            result: ToolResult(content: call.status == .failed ? "Web request failed." : "Completed. Sources appear in the answer.",
                                               isError: call.status == .failed),
                            serverName: "Web", hostedBy: "OpenAI")
        default: return nil
        }
    }

    static func citedText(_ item: OutputItem) -> String? {
        guard case let .outputMessage(message) = item else { return nil }
        return message.content.compactMap { content -> String? in
            guard case let .outputTextContent(output) = content else { return nil }
            var text = output.text
            // Offsets refer to the original Unicode text. Work backwards so insertions don't shift them.
            let citations = output.annotations.compactMap { annotation -> Components.Schemas.UrlCitationBody? in
                guard case let .urlCitationBody(citation) = annotation else { return nil }
                return citation
            }.sorted { $0.endIndex > $1.endIndex }
            for citation in citations {
                guard let url = URL(string: citation.url),
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { continue }
                let title = citation.title.isEmpty ? (url.host ?? "Source") : citation.title
                let label = title.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    .replacingOccurrences(of: "\n", with: " ")
                let destination = url.absoluteString.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                let link = " [\(label)](<\(destination)>)"
                let scalars = text.unicodeScalars
                guard citation.startIndex >= 0, citation.endIndex >= citation.startIndex,
                      citation.endIndex <= scalars.count else { text += link; continue }
                let start = scalars.index(scalars.startIndex, offsetBy: citation.startIndex)
                let end = scalars.index(scalars.startIndex, offsetBy: citation.endIndex)
                if text[start..<end].contains(Self.citationMarker) {
                    text.replaceSubrange(start..<end, with: link)
                } else {
                    text.insert(contentsOf: link, at: end)
                }
            }
            return text
        }.joined()
    }
}
