import IdentifiedCollections
import Foundation

nonisolated struct Conversation: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chat
        case code
    }

    let id: UUID
    var kind: Kind
    var title: String
    /// The model this chat last replied with, so reopening it picks up where it left off.
    var modelID: ChatModel.ID?
    var messages: IdentifiedArrayOf<Message>
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        kind: Kind = .chat,
        title: String,
        modelID: ChatModel.ID? = nil,
        messages: IdentifiedArrayOf<Message> = [],
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.modelID = modelID
        self.messages = messages
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

nonisolated extension Conversation.Kind {
    /// Instructions prepended to the user's own system prompt.
    var systemPrompt: String? {
        switch self {
        case .chat:
            nil
        case .code:
            """
            You are an expert software engineer pairing with the user. Write correct, idiomatic, \
            production-quality code. Prefer complete, runnable snippets in fenced code blocks tagged \
            with their language, and keep explanations short and to the point.
            """
        }
    }
}
