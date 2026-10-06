import Foundation

/// A remote Model Context Protocol server reached over Streamable HTTP.
///
/// A server either belongs to one provider (its "host") or, with no provider, works with all of them.
/// Servers are added by hand, connected from the connector directory, or inherited from a host's
/// `mcp.json`. Credentials (a token or an OAuth session) live in the Keychain.
nonisolated struct MCPServer: Codable, Equatable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Added by the user in Settings.
        case manual
        /// Discovered from the provider host's MCP configuration.
        case host
        /// A computer paired with the Hestrel account, reached through Hestrel's relay with the account's session.
        case computer
    }

    let id: UUID
    /// `nil` for servers that work with every provider, such as connectors.
    var providerID: Provider.ID?
    /// The directory entry this server was connected from, if any.
    var connectorID: Connector.ID?
    var name: String
    var url: String
    var isEnabled: Bool
    var origin: Origin
    /// Extra HTTP headers from the host configuration (manual servers keep their token in the Keychain).
    var headers: [String: String]

    init(
        id: UUID,
        providerID: Provider.ID?,
        connectorID: Connector.ID? = nil,
        name: String = "",
        url: String = "",
        isEnabled: Bool = true,
        origin: Origin = .manual,
        headers: [String: String] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.connectorID = connectorID
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

    var connector: Connector? { Connector.named(connectorID) }

    /// Whether the server's tools are offered when chatting with this provider.
    func isAvailable(to providerID: Provider.ID) -> Bool {
        self.providerID == nil || self.providerID == providerID
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
