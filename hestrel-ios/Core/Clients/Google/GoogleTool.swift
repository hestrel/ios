import Foundation

nonisolated enum GoogleTool: String, CaseIterable, Sendable {
    case gmailSearch = "hestrel_gmail_search"
    case gmailRead = "hestrel_gmail_read"
    case calendarList = "hestrel_calendar_list"
    case calendarEvents = "hestrel_calendar_events"
    case driveSearch = "hestrel_drive_search"
    case driveGet = "hestrel_drive_get"
    case driveRead = "hestrel_drive_read_document"

    var title: String {
        switch self {
        case .gmailSearch: "Gmail search"
        case .gmailRead: "Read email"
        case .calendarList: "Calendar list"
        case .calendarEvents: "Calendar events"
        case .driveSearch: "Drive search"
        case .driveGet: "File details"
        case .driveRead: "Read document"
        }
    }

    var service: GoogleService {
        switch self {
        case .gmailSearch, .gmailRead: .gmail
        case .calendarList, .calendarEvents: .calendar
        case .driveSearch, .driveGet, .driveRead: .drive
        }
    }

    var definition: ToolDefinition {
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        func field(_ name: String, _ description: String, required isRequired: Bool = false) {
            properties[name] = .object(["type": .string("string"), "description": .string(description)])
            if isRequired { required.append(name) }
        }
        let description: String
        switch self {
        case .gmailSearch:
            description = "Search the connected Gmail account. Returns message IDs; use hestrel_gmail_read to read them. Read-only."
            field("query", "Gmail search syntax, e.g. from:alice newer_than:7d", required: true)
            field("page_token", "Token from the previous page, if any")
        case .gmailRead:
            description = "Read a Gmail message by ID, including headers and text body. Read-only."
            field("message_id", "Message ID returned by Gmail search", required: true)
        case .calendarList:
            description = "List the calendars in the connected Google account. Read-only."
            field("page_token", "Token from the previous page, if any")
        case .calendarEvents:
            description = "List or search Google Calendar events in a time range. Read-only."
            field("calendar_id", "Calendar ID from calendar list, or primary")
            field("time_min", "Inclusive lower bound in RFC3339 with timezone, e.g. 2026-10-05T00:00:00+02:00", required: true)
            field("time_max", "Exclusive upper bound in RFC3339 with timezone", required: true)
            field("query", "Optional text to search in events")
            field("page_token", "Token from the previous page, if any")
        case .driveSearch:
            description = "Search Google Drive files by text. Returns IDs, titles, MIME types, and links. Read-only."
            field("query", "Plain text to search in file names and contents; empty to list recent files", required: true)
            field("page_token", "Token from the previous page, if any")
        case .driveGet:
            description = "Get metadata and a link for a Google Drive file by ID. Read-only."
            field("file_id", "File ID returned by Drive search", required: true)
        case .driveRead:
            description = "Read a Google Docs or Slides document as plain text, or the first sheet of a Google Sheets file as CSV. Does not read PDFs or other binary files. Read-only."
            field("file_id", "Google Workspace file ID returned by Drive search", required: true)
            properties["format"] = .object(["type": .string("string"), "enum": .array([.string("text"), .string("csv")]), "description": .string("Use csv for Sheets; text for Docs or Slides")])
        }
        return ToolDefinition(name: rawValue, description: description, inputSchema: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)
        ]))
    }

    /// Constructs only fixed, read-only Google endpoints. Model arguments never supply a URL or method.
    func request(arguments: String) throws -> URLRequest {
        guard let json = JSONValue(json: arguments), case .object = json else { throw GoogleToolError.invalidArguments }
        func string(_ key: String, required: Bool = false) throws -> String? {
            guard let value = json[key] else {
                if required { throw GoogleToolError.invalidArguments }
                return nil
            }
            guard let string = value.stringValue, string.count <= 4_000 else { throw GoogleToolError.invalidArguments }
            return string
        }
        func identifier(_ key: String, fallback: String? = nil) throws -> String {
            let value = try string(key) ?? fallback ?? ""
            guard !value.isEmpty, value != ".", value != "..", value.count <= 512,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-@.#+")).contains($0) }) else {
                throw GoogleToolError.invalidArguments
            }
            return value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        }
        var host = "www.googleapis.com"
        var path: String
        var query: [URLQueryItem] = []
        func add(_ key: String, _ value: String?) { if let value { query.append(.init(name: key, value: value)) } }
        switch self {
        case .gmailSearch:
            host = "gmail.googleapis.com"; path = "/gmail/v1/users/me/messages"
            add("q", try string("query", required: true)); add("maxResults", "20"); add("pageToken", try string("page_token"))
        case .gmailRead:
            host = "gmail.googleapis.com"; path = "/gmail/v1/users/me/messages/\(try identifier("message_id"))"
            add("format", "full")
        case .calendarList:
            path = "/calendar/v3/users/me/calendarList"
            add("maxResults", "50"); add("pageToken", try string("page_token"))
        case .calendarEvents:
            path = "/calendar/v3/calendars/\(try identifier("calendar_id", fallback: "primary"))/events"
            let lower = try string("time_min", required: true)!
            let upper = try string("time_max", required: true)!
            let formatter = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let start = formatter.date(from: lower) ?? fractional.date(from: lower),
                  let end = formatter.date(from: upper) ?? fractional.date(from: upper), start < end else { throw GoogleToolError.invalidArguments }
            add("timeMin", lower); add("timeMax", upper); add("q", try string("query"))
            add("singleEvents", "true"); add("orderBy", "startTime"); add("maxResults", "50"); add("pageToken", try string("page_token"))
        case .driveSearch:
            path = "/drive/v3/files"
            let value = try string("query", required: true)!
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            add("q", value.isEmpty ? "trashed = false" : "trashed = false and fullText contains '\(escaped)'")
            add("pageSize", "20"); add("orderBy", "modifiedTime desc"); add("pageToken", try string("page_token"))
            add("fields", "nextPageToken,files(id,name,mimeType,webViewLink,modifiedTime,description)")
        case .driveGet:
            path = "/drive/v3/files/\(try identifier("file_id"))"
            add("fields", "id,name,mimeType,webViewLink,modifiedTime,description,size")
        case .driveRead:
            path = "/drive/v3/files/\(try identifier("file_id"))/export"
            let format = try string("format") ?? "text"
            guard ["text", "csv"].contains(format) else { throw GoogleToolError.invalidArguments }
            add("mimeType", format == "csv" ? "text/csv" : "text/plain")
        }
        var url = URLComponents()
        url.scheme = "https"; url.host = host; url.percentEncodedPath = path; url.queryItems = query
        guard let endpoint = url.url else { throw GoogleToolError.invalidArguments }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }

    func result(data: Data) throws -> String {
        if self == .driveRead {
            guard let text = String(data: data, encoding: .utf8) else { throw GoogleToolError.unreadable }
            return String(text.prefix(40_000)) + (text.count > 40_000 ? "\n[Document truncated]" : "")
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard self == .gmailRead else { return json.jsonString() }
        func body(_ part: JSONValue) -> String {
            let children = part["parts"]?.arrayValue ?? []
            if !children.isEmpty {
                let plain = children.filter { $0["mimeType"]?.stringValue == "text/plain" }
                return (plain.isEmpty ? children : plain).map(body).joined(separator: "\n")
            }
            guard ["text/plain", "text/html"].contains(part["mimeType"]?.stringValue ?? ""),
                  let encoded = part["body"]?["data"]?.stringValue else { return "" }
            var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64) else { return "" }
            return String(decoding: bytes, as: UTF8.self)
        }
        let content = body(json["payload"] ?? .emptyObject)
        return JSONValue.object([
            "id": json["id"] ?? .null, "threadId": json["threadId"] ?? .null,
            "snippet": json["snippet"] ?? .null, "headers": json["payload"]?["headers"] ?? .array([]),
            "body": .string(String(content.prefix(40_000))), "truncated": .bool(content.count > 40_000)
        ]).jsonString()
    }
}

nonisolated enum GoogleToolError: LocalizedError {
    case invalidArguments, disconnected, unreadable, tooLarge
    case message(String)
    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid Google tool arguments. Check the tool schema and try again."
        case .disconnected: "This Google service is not connected or enabled. Open Plugins to connect it."
        case .unreadable: "This document could not be read as text."
        case .tooLarge: "The result is too large. Narrow the search or read a smaller document."
        case let .message(message): message
        }
    }
}
