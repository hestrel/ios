import Foundation
import XCTest
@testable import StreamAdapter

final class GoogleToolTests: XCTestCase {
    func testToolsRequireAccountScopeAndEnabledService() {
        var connection = GoogleConnection()
        connection.enabledServices = Set(GoogleService.allCases)
        connection.grantedScopes = Set(GoogleService.allCases.map(\.scope))
        XCTAssertTrue(connection.tools.isEmpty)
        connection.userID = "google-user"
        XCTAssertEqual(connection.tools.count, 7)
        connection.enabledServices.remove(.gmail)
        XCTAssertEqual(connection.tools.count, 5)
        connection.grantedScopes.remove(GoogleService.drive.scope)
        XCTAssertEqual(connection.tools.map(\.name), [GoogleTool.calendarList.rawValue, GoogleTool.calendarEvents.rawValue])
    }

    func testEveryToolUsesReadOnlyFixedGoogleEndpoints() throws {
        let arguments: [GoogleTool: String] = [
            .gmailSearch: #"{"query":"from:alice@example.com"}"#,
            .gmailRead: #"{"message_id":"abc123"}"#,
            .calendarList: "{}",
            .calendarEvents: #"{"calendar_id":"work@example.com","time_min":"2026-10-05T00:00:00+02:00","time_max":"2026-10-06T00:00:00+02:00"}"#,
            .driveSearch: #"{"query":"quarterly report"}"#,
            .driveGet: #"{"file_id":"abc_123-xyz"}"#,
            .driveRead: #"{"file_id":"abc_123-xyz","format":"csv"}"#
        ]
        for tool in GoogleTool.allCases {
            let request = try tool.request(arguments: XCTUnwrap(arguments[tool]))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertTrue(["www.googleapis.com", "gmail.googleapis.com"].contains(request.url!.host!))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
        }
    }

    func testIDsCannotInjectPathsOrURLs() {
        for id in ["../messages", "https://evil.example", "foo?alt=media", ".", "..", "a/b", ""] {
            let args = JSONValue.object(["file_id": .string(id)]).jsonString()
            XCTAssertThrowsError(try GoogleTool.driveGet.request(arguments: args))
        }
    }

    func testDriveQueryIsEscapedAndPaginated() throws {
        let request = try GoogleTool.driveSearch.request(arguments: #"{"query":"owner's \\ report","page_token":"next+page&token"}"#)
        let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(values.first { $0.name == "q" }?.value, "trashed = false and fullText contains 'owner\\'s \\\\ report'")
        XCTAssertEqual(values.first { $0.name == "pageToken" }?.value, "next+page&token")
    }

    func testBadArgumentsAndReversedDatesAreRejected() {
        XCTAssertThrowsError(try GoogleTool.gmailRead.request(arguments: "{}"))
        XCTAssertThrowsError(try GoogleTool.gmailSearch.request(arguments: #"{"query":42}"#))
        XCTAssertThrowsError(try GoogleTool.calendarEvents.request(arguments: #"{"time_min":"2026-10-06T00:00:00Z","time_max":"2026-10-05T00:00:00Z"}"#))
        XCTAssertThrowsError(try GoogleTool.driveRead.request(arguments: #"{"file_id":"abc","format":"application/pdf"}"#))
    }

    func testGmailBodyDecodesBase64URLWithoutBinaryAttachments() throws {
        let value = #"{"id":"abc","snippet":"Hello","payload":{"mimeType":"multipart/mixed","headers":[],"parts":[{"mimeType":"text/plain","body":{"data":"SGVsbG8g8J-MjQ"}},{"mimeType":"application/pdf","body":{"data":"c2VjcmV0IGJpbmFyeQ"}}]}}"#
        let result = try GoogleTool.gmailRead.result(data: Data(value.utf8))
        let json = try XCTUnwrap(JSONValue(json: result))
        XCTAssertEqual(json["body"]?.stringValue, "Hello 🌍")
        XCTAssertFalse(result.contains("secret binary"))
    }

    func testDocumentOutputIsBoundedAndMarkedTruncated() throws {
        let result = try GoogleTool.driveRead.result(data: Data(String(repeating: "a", count: 50_000).utf8))
        XCTAssertTrue(result.hasSuffix("[Document truncated]"))
        XCTAssertLessThan(result.count, 40_100)
    }
    func testMCPNamesCannotCollideWithBuiltInToolsAfterSanitization() {
        var catalog = ToolCatalog()
        let server = MCPServer(id: UUID(), providerID: UUID(), name: "External", url: "https://example.com/mcp")
        catalog.update([MCPTool(name: "hestrel/gmail_search", description: "External", inputSchema: .emptyObject)], for: server)
        XCTAssertEqual(catalog.tools.count, 1)
        XCTAssertNil(GoogleTool(rawValue: catalog.tools[0].exposedName))
        XCTAssertTrue(catalog.tools[0].exposedName.hasPrefix("mcp_"))
    }
}
