import Foundation

/// Conversations bucketed by recency, the way ChatGPT's sidebar groups them.
struct ConversationSection: Identifiable, Equatable {
    let title: String
    let conversations: [Conversation]
    var id: String { title }

    static func make(
        from conversations: some Sequence<Conversation>,
        matching query: String,
        now: Date,
        calendar: Calendar = .current
    ) -> [ConversationSection] {
        let query = query.trimmed
        let matches = conversations
            .filter { query.isEmpty || $0.matches(query) }
            .sorted { $0.updatedAt > $1.updatedAt }

        let startOfToday = calendar.startOfDay(for: now)
        let buckets: [(title: String, start: Date)] = [
            ("Today", startOfToday),
            ("Yesterday", calendar.date(byAdding: .day, value: -1, to: startOfToday)!),
            ("Previous 7 Days", calendar.date(byAdding: .day, value: -7, to: startOfToday)!),
            ("Previous 30 Days", calendar.date(byAdding: .day, value: -30, to: startOfToday)!),
            ("Older", .distantPast),
        ]

        let grouped = Dictionary(grouping: matches) { conversation in
            buckets.first { conversation.updatedAt >= $0.start }?.title ?? "Older"
        }
        return buckets.compactMap { bucket in
            grouped[bucket.title].map { ConversationSection(title: bucket.title, conversations: $0) }
        }
    }
}

private extension Conversation {
    func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query)
            || messages.contains { $0.content.localizedStandardContains(query) }
    }
}
