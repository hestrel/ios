/// Loading state of something fetched from a remote server, such as a provider's models or an MCP server's tools.
nonisolated enum LoadStatus: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}
