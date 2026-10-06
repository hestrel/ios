import Foundation

/// A coding agent on the user's computer, reached through Hestrel's bridge (`Tools/hestrel-bridge.mjs`):
/// Codex through `codex app-server`, Claude Code through `claude -p`, and any other harness (OpenCode, pi,
/// Gemini CLI, …) through the bridge's `agent_run` tool. The bridge lists those, so new ones need no app update.
nonisolated struct CodeAgent: Hashable, Identifiable, Sendable {
    let id: String
    /// Also marks the agent's steps in `ToolCall.hostedBy`.
    let title: String
    /// Whether the agent takes a reasoning effort.
    var supportsEffort = true

    static let codex = CodeAgent(id: "codex", title: "Codex")
    static let claudeCode = CodeAgent(id: "claudeCode", title: "Claude Code")
    static let builtIn = [codex, claudeCode]

    /// How the bridge runs the agent.
    enum Kind { case codex, claudeCode, harness }

    var kind: Kind {
        switch id {
        case Self.codex.id: .codex
        case Self.claudeCode.id: .claudeCode
        default: .harness
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The tool that starts a session, which identifies the servers offering this agent.
    var startTool: String {
        switch kind {
        case .codex: "codex"
        case .claudeCode: "claude_code"
        case .harness: Self.harnessTool
        }
    }

    static let codexReplyTool = "codex-reply"
    static let harnessTool = "agent_run"
    static let harnessModelsTool = "agent_models"

    /// Where the agent's default model comes from, for the model picker.
    var defaultModelDescription: String {
        switch kind {
        case .codex: "The model in your Codex config"
        case .claudeCode, .harness: "\(title)’s default model"
        }
    }

    /// Claude Code's aliases, which always point at the latest model of each family.
    static let claudeModels = [
        CodeModel(id: "fable", title: "Fable"),
        CodeModel(id: "opus", title: "Opus"),
        CodeModel(id: "sonnet", title: "Sonnet"),
        CodeModel(id: "haiku", title: "Haiku"),
    ]

    /// A readable name for a model the agent reported: "claude-haiku-4-5-20251001" reads "Haiku 4.5".
    func displayName(forModel model: String, options: [CodeModel]) -> String {
        if let option = options.first(where: { $0.id == model }) { return option.title }
        guard kind == .claudeCode, model.hasPrefix("claude-") else { return model }
        let parts = String(model.dropFirst("claude-".count)).split(separator: "-").map(String.init).filter { $0.count < 8 }
        guard let family = parts.first(where: { $0.allSatisfy(\.isLetter) }) else { return model }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    /// The tool and arguments for the next turn: a new session with the session's settings, or a continuation of it.
    func turn(prompt: String, session: Conversation.CodeSession, resume: Bool = true) -> (tool: String, arguments: JSONValue) {
        let threadID = resume ? session.threadID : nil
        var arguments: [String: JSONValue] = ["prompt": .string(prompt)]

        switch kind {
        case .codex:
            if let threadID {
                return (Self.codexReplyTool, .object(["threadId": .string(threadID), "prompt": .string(prompt)]))
            }
            // Nobody can answer Codex's approval prompts from here, and writes stay inside the folder.
            arguments["approval-policy"] = .string("never")
            arguments["sandbox"] = .string("workspace-write")
            if let effort = session.effort.apiValue {
                arguments["config"] = .object(["model_reasoning_effort": .string(effort)])
            }
        case .claudeCode:
            // Claude Code saves sessions on disk, so the bridge resumes them with the original settings.
            if let threadID {
                arguments["session_id"] = .string(threadID)
            }
            if let effort = session.effort.apiValue {
                arguments["effort"] = .string(effort)
            }
        case .harness:
            arguments["agent"] = .string(id)
            if let threadID {
                arguments["session_id"] = .string(threadID)
            }
            if supportsEffort, let effort = session.effort.apiValue {
                arguments["effort"] = .string(effort)
            }
        }
        if let folder = session.folder.nonBlank {
            arguments["cwd"] = .string(folder)
        }
        if let model = session.model {
            arguments["model"] = .string(model)
        }
        return (startTool, .object(arguments))
    }

    /// A continuation the agent can't find, e.g. after a Codex bridge restarted. The bridge reports it this way for every agent.
    static func isLostSession(_ result: ToolResult) -> Bool {
        result.isError && result.content.hasPrefix("Session not found")
    }

    /// A prompt for a fresh session that carries on a conversation whose session is gone.
    func recap(of messages: [Message], then prompt: String) -> String {
        var transcript: [String] = []
        for message in messages {
            let text = message.content.trimmed
            guard !text.isEmpty else { continue }
            let clipped = text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text
            switch message.role {
            case .user: transcript.append("User: \(clipped)")
            case .assistant: transcript.append("\(title): \(clipped)")
            }
        }
        // Long sessions keep their most recent turns.
        var recap = transcript.joined(separator: "\n\n")
        if recap.count > 12_000 { recap = "…" + recap.suffix(12_000) }
        return """
        This continues an earlier session in this folder whose context was lost. The conversation so far:

        \(recap)

        New request:
        \(prompt)
        """
    }

    /// A tool result without the structured block `MCPConnection` appends for models.
    static func answer(from content: String) -> String {
        guard let range = content.range(of: "\n\nStructured result:\n") else { return content }
        return String(content[..<range.lowerBound])
    }
}

/// Sessions store the agent by ID with its title, so a harness the computer no longer offers still reads well.
nonisolated extension CodeAgent: Codable {
    private enum CodingKeys: String, CodingKey { case id, title, supportsEffort }

    init(from decoder: any Decoder) throws {
        // Sessions from before harnesses stored just "codex" or "claudeCode".
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self = Self.builtIn.first { $0.id == id } ?? CodeAgent(id: id, title: id)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        supportsEffort = try container.decodeIfPresent(Bool.self, forKey: .supportsEffort) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(supportsEffort, forKey: .supportsEffort)
    }
}

nonisolated extension Conversation.CodeSession {
    /// The terminal command that opens this session on the computer, once the agent has started it.
    var resumeCommand: String? {
        guard let threadID else { return nil }
        let resume: String
        switch agent.id {
        case CodeAgent.codex.id: resume = "codex resume \(threadID)"
        case CodeAgent.claudeCode.id: resume = "claude --resume \(threadID)"
        case "opencode": resume = "opencode --session \(threadID)"
        case "pi": resume = "pi --session-id \(threadID)"
        default: return nil
        }
        // Claude Code finds sessions by folder, so start where the session ran.
        guard let folder = folder.nonBlank else { return resume }
        return "cd \(Self.shellQuoted(folder)) && \(resume)"
    }

    /// A path as a shell word: plain when it's safe, single-quoted otherwise. A leading `~` stays unquoted so it expands.
    private static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./~+@%")
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        let (home, rest) = path.hasPrefix("~/") ? ("~/", String(path.dropFirst(2))) : ("", path)
        return home + "'" + rest.replacing("'", with: "'\\''") + "'"
    }
}

/// A model a coding agent can run: its name or alias, and how it's shown.
nonisolated struct CodeModel: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

nonisolated extension ToolCatalog {
    /// Servers offering an agent's sessions.
    func serverIDs(offering agent: CodeAgent) -> [MCPServer.ID] {
        var seen = Set<MCPServer.ID>()
        return codeAgentsByServer.compactMap { serverID, agents in
            agents.contains(agent) && seen.insert(serverID).inserted ? serverID : nil
        }
    }

    /// The coding agents one server offers, in the bridge's order.
    func codeAgents(on serverID: MCPServer.ID) -> [CodeAgent] {
        codeAgentsByServer.first { $0.serverID == serverID }?.agents ?? []
    }

    /// Every server's coding agents: the built-in ones by their tools, the rest from `agent_run`'s list.
    private var codeAgentsByServer: [(serverID: MCPServer.ID, agents: [CodeAgent])] {
        var order: [MCPServer.ID] = []
        var agents: [MCPServer.ID: [CodeAgent]] = [:]
        for tool in tools {
            var found = CodeAgent.builtIn.filter { $0.startTool == tool.name }
            if tool.name == CodeAgent.harnessTool {
                found = Self.harnesses(in: tool.inputSchema)
            }
            guard !found.isEmpty else { continue }
            if agents[tool.serverID] == nil { order.append(tool.serverID) }
            agents[tool.serverID, default: []] += found
        }
        return order.map { ($0, agents[$0] ?? []) }
    }

    /// `agent_run`'s `agent` parameter: `oneOf` entries with each harness's ID and name.
    private static func harnesses(in schema: JSONValue) -> [CodeAgent] {
        (schema["properties"]?["agent"]?["oneOf"]?.arrayValue ?? []).compactMap { option in
            guard let id = option["const"]?.stringValue else { return nil }
            return CodeAgent(id: id, title: option["title"]?.stringValue ?? id, supportsEffort: option["x-hestrel-effort"]?.boolValue ?? false)
        }
    }
}
