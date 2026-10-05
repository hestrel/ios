import Foundation

nonisolated struct ChatRequest: Sendable {
    struct Turn: Equatable, Sendable {
        let role: Message.Role
        let content: String
        /// Images attached to a user turn.
        var images: [ImageInput] = []
        /// Tools the assistant called in this turn, each with its result.
        var toolCalls: [ToolCall] = []
    }

    var provider: Provider
    var apiKey: String?
    var model: String
    var systemPrompt: String?
    var turns: [Turn]
    /// How hard reasoning models should think; `auto` leaves the model's default.
    var reasoningEffort = ReasoningEffort.auto
    /// The provider's built-in web search (OpenAI, Anthropic). Off for background title requests.
    var webSearchEnabled = false
    /// Tools the app executes itself.
    var tools: [ToolDefinition] = []
    /// MCP servers the provider connects to on its own.
    var hostedMCPServers: [HostedMCPServer] = []
}

/// A single piece of a streamed response.
nonisolated enum ChatStreamEvent: Equatable, Sendable {
    case text(String)
    case textReplaced(String)
    case reasoning(String)
    /// A fully-assembled tool call. Calls the provider already ran arrive with their result attached.
    case toolCall(ToolCall)
}
