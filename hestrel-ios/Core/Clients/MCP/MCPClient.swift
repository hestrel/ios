import ComposableArchitecture
import Foundation

@DependencyClient
nonisolated struct MCPClient: Sendable {
    /// Reads the MCP servers a model host publishes in its `mcp.json`.
    var discoverServers: @Sendable (_ configURL: String) async throws -> MCPHostConfig.Discovery
    var listTools: @Sendable (_ server: MCPServer, _ headers: [String: String]) async throws -> [MCPTool]
    var callTool: @Sendable (_ server: MCPServer, _ headers: [String: String], _ name: String, _ arguments: String) async throws -> ToolResult
}

nonisolated extension MCPClient: DependencyKey {
    static let liveValue: MCPClient = {
        /// One session per server, recreated whenever its URL or headers change.
        let connections = LockIsolated<[MCPServer.ID: MCPConnection]>([:])

        @Sendable func connection(for server: MCPServer, headers: [String: String]) throws -> MCPConnection {
            guard let url = URL(string: server.url.trimmed), server.hasValidURL else {
                throw MCPError.invalidURL(server.url)
            }
            return connections.withValue { connections in
                if let existing = connections[server.id], existing.url == url, existing.headers == headers {
                    return existing
                }
                let connection = MCPConnection(url: url, headers: headers)
                connections[server.id] = connection
                return connection
            }
        }

        return MCPClient(
            discoverServers: { configURL in
                let url = try Endpoint.url(configURL)
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, headers: [:], timeout: 10))
                try HTTPTransport.validate(response, body: data)
                return try MCPHostConfig.parse(data, configURL: url)
            },
            listTools: { server, headers in
                try await connection(for: server, headers: headers).listTools()
            },
            callTool: { server, headers, name, arguments in
                try await connection(for: server, headers: headers)
                    .callTool(name: name, arguments: JSONValue(json: arguments) ?? .emptyObject)
            }
        )
    }()

    static let previewValue = MCPClient(
        discoverServers: { _ in
            MCPHostConfig.Discovery(servers: [DiscoveredMCPServer(name: "filesystem", url: "http://localhost:8931/mcp", headers: [:])], skipped: [])
        },
        listTools: { _, _ in
            [MCPTool(name: "get_weather", description: "Current weather for a city.", inputSchema: .object(["type": .string("object")]))]
        },
        callTool: { _, _, _, _ in
            ToolResult(content: "Sunny, 22°C", isError: false)
        }
    )

    static let testValue = MCPClient()
}

nonisolated extension DependencyValues {
    var mcp: MCPClient {
        get { self[MCPClient.self] }
        set { self[MCPClient.self] = newValue }
    }
}

nonisolated extension MCPServer {
    /// Headers to authenticate with this server: the host config's headers, or the Keychain token for manual servers.
    func authHeaders(token: String?) -> [String: String] {
        var headers = self.headers
        if let token = token?.nonBlank {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
}
