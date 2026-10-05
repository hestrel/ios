import Foundation

/// An MCP server listed in a host's configuration file.
nonisolated struct DiscoveredMCPServer: Equatable, Sendable {
    let name: String
    let url: String
    let headers: [String: String]
}

/// Parses the `mcp.json` a model host publishes, in the format used by Claude Desktop, LM Studio and Cursor
/// (`{"mcpServers": {...}}`) or VS Code (`{"servers": {...}}`).
///
/// Only HTTP servers can be reached from iOS; `command`-based stdio servers are reported as skipped.
nonisolated enum MCPHostConfig {
    struct Discovery: Equatable, Sendable {
        var servers: [DiscoveredMCPServer]
        /// Names of stdio servers that can't run on iOS.
        var skipped: [String]
    }

    static func parse(_ data: Data, configURL: URL) throws -> Discovery {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(entries) = root["mcpServers"] ?? root["servers"] ?? .object([:])
        else { throw MCPError.invalidConfig }

        var discovery = Discovery(servers: [], skipped: [])
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let rawURL = entry["url"]?.stringValue ?? entry["serverUrl"]?.stringValue ?? entry["httpUrl"]?.stringValue else {
                discovery.skipped.append(name)
                continue
            }
            var headers: [String: String] = [:]
            if case let .object(object) = entry["headers"] ?? .null {
                for (field, value) in object {
                    if let value = value.stringValue { headers[field] = value }
                }
            }
            discovery.servers.append(DiscoveredMCPServer(
                name: name,
                url: rewriteLoopback(rawURL, toHostOf: configURL),
                headers: headers
            ))
        }
        return discovery
    }

    /// `localhost` in the host's config means the host itself, not this phone.
    static func rewriteLoopback(_ urlString: String, toHostOf configURL: URL) -> String {
        guard var components = URLComponents(string: urlString),
              let host = components.host,
              ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host),
              let configHost = configURL.host()
        else { return urlString }
        components.host = configHost
        return components.string ?? urlString
    }
}
