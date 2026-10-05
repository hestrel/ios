import IdentifiedCollections
import Foundation

/// A configured connection to an LLM backend. API keys are kept in the Keychain, never here.
nonisolated struct Provider: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var isEnabled: Bool
    /// Where a self-hosted provider publishes its MCP servers, e.g. `http://192.168.1.10:8000/mcp.json`.
    var mcpConfigURL: String

    init(
        id: UUID,
        kind: ProviderKind,
        name: String? = nil,
        baseURL: String? = nil,
        isEnabled: Bool = false,
        mcpConfigURL: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.displayName
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.isEnabled = isEnabled
        self.mcpConfigURL = mcpConfigURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // Added with MCP support.
        mcpConfigURL = try container.decodeIfPresent(String.self, forKey: .mcpConfigURL) ?? ""
    }

    var hasValidBaseURL: Bool {
        guard let url = URL(string: baseURL.trimmed), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }
}

nonisolated extension Provider {
    /// Providers offered out of the box. They start disabled until the user configures them.
    static let presets: IdentifiedArrayOf<Provider> = [
        Provider(id: UUID(uuidString: "6F1C2A9E-0001-4C1B-9D51-6A1E0F7B0001")!, kind: .openAI),
        Provider(id: UUID(uuidString: "6F1C2A9E-0002-4C1B-9D51-6A1E0F7B0002")!, kind: .anthropic),
        Provider(id: UUID(uuidString: "6F1C2A9E-0003-4C1B-9D51-6A1E0F7B0003")!, kind: .gemini),
        Provider(id: UUID(uuidString: "6F1C2A9E-0004-4C1B-9D51-6A1E0F7B0004")!, kind: .ollama),
    ]
}
