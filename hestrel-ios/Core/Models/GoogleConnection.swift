import Foundation

nonisolated enum GoogleService: String, Codable, CaseIterable, Identifiable, Sendable {
    case gmail, calendar, drive
    var id: Self { self }
    var title: String {
        switch self { case .gmail: "Gmail"; case .calendar: "Google Calendar"; case .drive: "Google Drive" }
    }
    var symbol: String {
        switch self { case .gmail: "envelope"; case .calendar: "calendar"; case .drive: "externaldrive" }
    }
    var detail: String {
        switch self {
        case .gmail: "Search and read email"
        case .calendar: "Find calendars and events"
        case .drive: "Find files and read Google documents"
        }
    }
    var scope: String { "https://www.googleapis.com/auth/\(rawValue).readonly" }
}

/// Only account metadata and enabled services are persisted here. The Google SDK keeps tokens in Keychain.
nonisolated struct GoogleConnection: Codable, Equatable, Sendable {
    var userID: String?
    var email: String?
    var grantedScopes: Set<String> = []
    var enabledServices: Set<GoogleService> = []

    func isAvailable(_ service: GoogleService) -> Bool {
        userID != nil && enabledServices.contains(service) && grantedScopes.contains(service.scope)
    }

    var tools: [ToolDefinition] {
        GoogleTool.allCases.filter { isAvailable($0.service) }.map(\.definition)
    }
}
