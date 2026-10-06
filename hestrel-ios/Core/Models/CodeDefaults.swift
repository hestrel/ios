import Foundation

/// The settings new code sessions start with, remembered from the last choices.
nonisolated struct CodeDefaults: Codable, Equatable, Sendable {
    var agent = CodeAgent.codex
    /// The working folder; empty for the folder the bridge runs in.
    var folder = ""
    /// Each agent's model, by agent; missing means the agent's own default.
    var models: [String: String] = [:]
    var effort = ReasoningEffort.auto

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(CodeAgent.self, forKey: .agent) ?? .codex
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? ""
        models = try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        effort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .effort) ?? .auto
    }

    func model(for agent: CodeAgent) -> String? {
        models[agent.id]
    }
}
