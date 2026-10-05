import Foundation

nonisolated struct Message: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    var attachments: [Attachment]
    var reasoning: String
    var toolCalls: [ToolCall]
    var modelName: String?
    var errorDescription: String?
    let createdAt: Date

    init(
        id: UUID,
        role: Role,
        content: String = "",
        attachments: [Attachment] = [],
        reasoning: String = "",
        toolCalls: [ToolCall] = [],
        modelName: String? = nil,
        errorDescription: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.modelName = modelName
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        // `toolCalls` was added with MCP support; older messages have none.
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

nonisolated extension Message {
    /// What the UI should render for this message.
    ///
    /// Some local models stream their chain of thought inline as `<think>…</think>`
    /// instead of in a dedicated field, so it gets split out of the visible answer here.
    struct Display: Equatable {
        var reasoning: String
        var answer: String
        var isReasoningInProgress: Bool
    }

    var display: Display {
        guard let open = content.range(of: "<think>") else {
            return Display(reasoning: reasoning.trimmed, answer: content, isReasoningInProgress: false)
        }
        let leading = content[..<open.lowerBound]
        let afterOpen = content[open.upperBound...]
        guard let close = afterOpen.range(of: "</think>") else {
            return Display(
                reasoning: (reasoning + afterOpen).trimmed,
                answer: String(leading),
                isReasoningInProgress: true
            )
        }
        return Display(
            reasoning: (reasoning + afterOpen[..<close.lowerBound]).trimmed,
            answer: (leading + afterOpen[close.upperBound...]).trimmed,
            isReasoningInProgress: false
        )
    }

    /// Tool calls the app ran to completion, which can be replayed to the model as history.
    var replayableToolCalls: [ToolCall] {
        toolCalls.filter { $0.result != nil && !$0.isHosted }
    }

    /// Whether this message should be sent back to the model as conversation history.
    var isPartOfHistory: Bool {
        errorDescription == nil && (!display.answer.trimmed.isEmpty || !attachments.isEmpty || !replayableToolCalls.isEmpty)
    }
}
