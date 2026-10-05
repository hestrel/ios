import Foundation

/// A remote Model Context Protocol server reached over Streamable HTTP.
///
/// Every server belongs to a provider (its "host"). Servers are either added by hand, with an
/// optional bearer token kept in the Keychain, or inherited from the host's own `mcp.json`.
nonisolated struct MCPServer: Codable, Equatable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Added by the user in Settings.
        case manual
        /// Discovered from the provider host's MCP configuration.
        case host
    }

    let id: UUID
    var providerID: Provider.ID
    var name: String
    var url: String
    var isEnabled: Bool
    var origin: Origin
    /// Extra HTTP headers from the host configuration (manual servers keep their token in the Keychain).
    var headers: [String: String]

    init(
        id: UUID,
        providerID: Provider.ID,
        name: String = "",
        url: String = "",
        isEnabled: Bool = true,
        origin: Origin = .manual,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.origin = origin
        self.headers = headers
    }

    var hasValidURL: Bool {
        guard let url = URL(string: url.trimmed), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }

    var displayHost: String {
        URL(string: url)?.host() ?? url
    }
}

/// A tool advertised by an MCP server.
nonisolated struct MCPTool: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// An MCP server the provider connects to itself (Anthropic's MCP connector, OpenAI's remote MCP tool).
nonisolated struct HostedMCPServer: Equatable, Sendable {
    let name: String
    let url: String
    let headers: [String: String]

    var bearerToken: String? {
        guard let value = headers.first(where: { $0.key.lowercased() == "authorization" })?.value else { return nil }
        return value.hasPrefix("Bearer ") ? String(value.dropFirst(7)) : value
    }
}
