import IdentifiedCollections
import Foundation

nonisolated struct Conversation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chat
        /// A coding agent's session on the user's computer.
        case code
    }

    /// Where a code conversation's agent session runs, and how.
    struct CodeSession: Codable, Equatable, Sendable {
        var agent: CodeAgent
        var serverID: MCPServer.ID
        /// The working folder on the computer; empty for the folder the bridge was started in.
        var folder: String
        /// The model slug, or `nil` for the one in the computer's Codex config.
        var model: String?
        var effort: ReasoningEffort = .auto
        /// Set once the agent has started the session; later prompts continue it.
        var threadID: String?
        /// The stream of a turn still running on the computer, so a relaunched app can pick its reply back up.
        var pendingStreamID: String?

        init(agent: CodeAgent, serverID: MCPServer.ID, folder: String, model: String? = nil, effort: ReasoningEffort = .auto, threadID: String? = nil) {
            self.agent = agent
            self.serverID = serverID
            self.folder = folder
            self.model = model
            self.effort = effort
            self.threadID = threadID
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agent = try container.decodeIfPresent(CodeAgent.self, forKey: .agent) ?? .codex
            serverID = try container.decode(MCPServer.ID.self, forKey: .serverID)
            folder = try container.decode(String.self, forKey: .folder)
            model = try container.decodeIfPresent(String.self, forKey: .model)
            effort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .effort) ?? .auto
            threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
            pendingStreamID = try container.decodeIfPresent(String.self, forKey: .pendingStreamID)
        }
    }

    let id: UUID
    var kind: Kind
    var title: String
    /// The model this chat last replied with, so reopening it picks up where it left off.
    var modelID: ChatModel.ID?
    var messages: IdentifiedArrayOf<Message>
    var codeSession: CodeSession?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        kind: Kind = .chat,
        title: String,
        modelID: ChatModel.ID? = nil,
        messages: IdentifiedArrayOf<Message> = [],
        codeSession: CodeSession? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.modelID = modelID
        self.messages = messages
        self.codeSession = codeSession
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // `kind` was added after the first release; older chats are plain chats.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .chat
        title = try container.decode(String.self, forKey: .title)
        modelID = try container.decodeIfPresent(ChatModel.ID.self, forKey: .modelID)
        messages = try container.decode(IdentifiedArrayOf<Message>.self, forKey: .messages)
        codeSession = try container.decodeIfPresent(CodeSession.self, forKey: .codeSession)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

nonisolated extension Conversation {
    /// A provisional title derived from the first prompt, shown until the model suggests a better one.
    static func provisionalTitle(for prompt: String) -> String {
        let firstLine = prompt.trimmed.components(separatedBy: .newlines).first ?? ""
        return firstLine.count > 48 ? String(firstLine.prefix(48)) + "…" : firstLine
    }
}
