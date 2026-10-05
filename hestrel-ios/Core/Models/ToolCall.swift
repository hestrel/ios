import Foundation

/// A tool invocation requested by the model, and its outcome once it has run.
nonisolated struct ToolCall: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The tool name as exposed to the model.
    let name: String
    /// The JSON arguments the model produced.
    let arguments: String
    var result: ToolResult?
    /// The MCP server that provides the tool, when known.
    var serverName: String?
    /// The provider that executed the call server-side, e.g. "Anthropic". `nil` when the app ran it.
    var hostedBy: String?

    init(
        id: String,
        name: String,
        arguments: String,
        result: ToolResult? = nil,
        serverName: String? = nil,
        hostedBy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.serverName = serverName
        self.hostedBy = hostedBy
    }

    /// Calls run by the provider can't be replayed as client tool calls; only their effect on the answer remains.
    var isHosted: Bool { hostedBy != nil }
}

nonisolated struct ToolResult: Codable, Equatable, Sendable {
    var content: String
    var isError: Bool
}

/// A tool offered to the model in a chat request, executed by the app.
nonisolated struct ToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}
