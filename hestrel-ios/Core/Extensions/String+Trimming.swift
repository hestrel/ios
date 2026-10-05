import Foundation

nonisolated extension StringProtocol {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `nil` when the string is empty or contains only whitespace.
    var nonBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}
