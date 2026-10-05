import IdentifiedCollections
import Foundation

/// Tools discovered from every enabled MCP server, plus the loading state of each server.
nonisolated struct ToolCatalog: Equatable, Sendable {
    struct Tool: Equatable, Identifiable, Sendable {
        let serverID: MCPServer.ID
        /// The name the MCP server knows the tool by.
        let name: String
        /// A unique, API-safe name shown to the model.
        let exposedName: String
        let description: String
        let inputSchema: JSONValue

        var id: String { exposedName }

        var definition: ToolDefinition {
            ToolDefinition(name: exposedName, description: description, inputSchema: inputSchema)
        }
    }

    /// The outcome of reading a host's `mcp.json`.
    struct Discovery: Equatable, Sendable {
        var status: LoadStatus
        /// stdio servers listed by the host, which iOS can't launch.
        var skipped: [String] = []
    }

    private(set) var tools: IdentifiedArrayOf<Tool> = []
    private(set) var statuses: [MCPServer.ID: LoadStatus] = [:]
    private(set) var discoveryStatuses: [Provider.ID: Discovery] = [:]

    mutating func setDiscovery(_ discovery: Discovery?, for providerID: Provider.ID) {
        discoveryStatuses[providerID] = discovery
    }

    func tools(for serverID: MCPServer.ID) -> [Tool] {
        tools.filter { $0.serverID == serverID }
    }

    mutating func beginLoading(_ serverIDs: Set<MCPServer.ID>) {
        tools.removeAll { !serverIDs.contains($0.serverID) }
        statuses = Dictionary(uniqueKeysWithValues: serverIDs.map { ($0, .loading) })
    }

    mutating func update(_ newTools: [MCPTool], for server: MCPServer) {
        tools.removeAll { $0.serverID == server.id }
        for tool in newTools {
            tools.append(Tool(
                serverID: server.id,
                name: tool.name,
                exposedName: exposedName(for: tool.name, server: server),
                description: tool.description,
                inputSchema: tool.inputSchema
            ))
        }
        statuses[server.id] = .ready
    }

    mutating func fail(_ message: String, for serverID: MCPServer.ID) {
        tools.removeAll { $0.serverID == serverID }
        statuses[serverID] = .failed(message)
    }

    /// Model APIs only accept `[A-Za-z0-9_-]{1,64}` tool names, and names must be unique across servers.
    private func exposedName(for name: String, server: MCPServer) -> String {
        let sanitized = Self.sanitize(name)
        let base = sanitized.hasPrefix("hestrel_") ? Self.sanitize("mcp_\(server.id.uuidString.prefix(8))_\(sanitized)") : sanitized
        guard tools[id: base] != nil else { return base }
        return Self.sanitize("\(server.name)_\(name)")
    }

    /// Restricts a name to the characters model APIs accept for tool and server names.
    static func sanitize(_ name: String) -> String {
        let allowed = name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" }
        return String(String(allowed).prefix(64))
    }
}
