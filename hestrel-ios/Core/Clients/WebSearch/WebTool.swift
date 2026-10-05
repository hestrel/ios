import Foundation

/// Web search tools the app runs itself, for providers without a built-in search.
nonisolated enum WebTool: String, CaseIterable, Sendable {
    case search = "hestrel_web_search"
    case fetch = "hestrel_web_fetch"

    var definition: ToolDefinition {
        switch self {
        case .search:
            ToolDefinition(
                name: rawValue,
                description: "Search the web for current information. Returns titles, URLs and snippets; use hestrel_web_fetch to read a result.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "description": .string("What to search for")]),
                    ]),
                    "required": .array([.string("query")]),
                ])
            )
        case .fetch:
            ToolDefinition(
                name: rawValue,
                description: "Read a web page as plain text. Use it on URLs from hestrel_web_search or ones the user shared.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object(["type": .string("string"), "description": .string("An http or https URL")]),
                    ]),
                    "required": .array([.string("url")]),
                ])
            )
        }
    }
}

nonisolated extension ProviderKind {
    /// Providers whose servers search the web themselves; the rest use `WebTool` on this device.
    var hasBuiltInWebSearch: Bool {
        switch self {
        case .openAI, .anthropic: true
        case .gemini, .ollama, .openAICompatible: false
        }
    }
}
