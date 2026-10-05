import ComposableArchitecture
import Foundation

/// Runs `WebTool` calls: searches through DuckDuckGo's HTML results page and reads pages as text.
@DependencyClient
nonisolated struct WebSearchClient: Sendable {
    var call: @Sendable (_ name: String, _ arguments: String) async throws -> ToolResult
}

nonisolated enum WebSearchError: LocalizedError {
    case missingArgument(String)
    case invalidURL
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name): "The “\(name)” argument is required."
        case .invalidURL: "That isn’t an http or https URL."
        case let .http(status): "The site responded with HTTP \(status)."
        case .unreadable: "The page couldn’t be read as text."
        }
    }
}

nonisolated extension WebSearchClient: DependencyKey {
    /// Pages are cut to this many characters so one result can't flood the model's context.
    static let maxPageCharacters = 12_000
    static let maxResults = 8

    static let liveValue = WebSearchClient(
        call: { name, arguments in
            let input = JSONValue(json: arguments) ?? .emptyObject
            switch WebTool(rawValue: name) {
            case .search:
                guard let query = input["query"]?.stringValue?.nonBlank else { throw WebSearchError.missingArgument("query") }
                return ToolResult(content: try await search(query), isError: false)
            case .fetch:
                guard let url = input["url"]?.stringValue.flatMap(URL.init(string:)),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                else { throw WebSearchError.invalidURL }
                return ToolResult(content: try await fetch(url), isError: false)
            case nil:
                throw WebSearchError.missingArgument("name")
            }
        }
    )

    static let testValue = WebSearchClient()

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Fetches a page, retrying once after a transient network failure such as a TLS hiccup while
    /// the phone switches networks.
    private static func get(_ url: URL) async throws -> String {
        do {
            return try await getOnce(url)
        } catch let error as URLError where error.isTransient {
            try await Task.sleep(for: .milliseconds(600))
            return try await getOnce(url)
        }
    }

    private static func getOnce(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebSearchError.http(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebSearchError.unreadable
        }
        return html
    }

    /// DuckDuckGo serves the same results page from two addresses; the second is a fallback.
    private static let searchEndpoints = ["https://html.duckduckgo.com/html/", "https://duckduckgo.com/html/"]

    private static func search(_ query: String) async throws -> String {
        var html: String?
        var lastError: (any Error)?
        for endpoint in searchEndpoints where html == nil {
            var components = URLComponents(string: endpoint)!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            do {
                html = try await get(components.url!)
            } catch {
                lastError = error
            }
        }
        guard let html else { throw lastError ?? WebSearchError.unreadable }
        let results = DuckDuckGoResults.parse(html).prefix(maxResults)
        guard !results.isEmpty else { return "No results for “\(query)”." }
        return results.enumerated().map { index, result in
            "\(index + 1). \(result.title)\n\(result.url)\n\(result.snippet)"
        }.joined(separator: "\n\n")
    }

    private static func fetch(_ url: URL) async throws -> String {
        let text = HTMLText.plainText(from: try await get(url))
        guard !text.isEmpty else { throw WebSearchError.unreadable }
        return text.count > maxPageCharacters ? String(text.prefix(maxPageCharacters)) + "\n…" : text
    }
}

nonisolated extension DependencyValues {
    var webSearch: WebSearchClient {
        get { self[WebSearchClient.self] }
        set { self[WebSearchClient.self] = newValue }
    }
}

/// Results scraped from `html.duckduckgo.com`. Unofficial, so it fails soft: unparseable markup yields no results.
nonisolated enum DuckDuckGoResults {
    struct Result: Equatable, Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    static func parse(_ html: String) -> [Result] {
        let links = matches(of: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(of: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#, in: html).map { $0[0] }
        return links.enumerated().compactMap { index, groups in
            guard let url = destination(of: HTMLText.decodeEntities(groups[0])) else { return nil }
            return Result(
                title: HTMLText.plainText(from: groups[1]),
                url: url,
                snippet: index < snippets.count ? HTMLText.plainText(from: snippets[index]) : ""
            )
        }
    }

    /// Result links go through a redirect like `//duckduckgo.com/l/?uddg=<encoded URL>`; ads are dropped.
    private static func destination(of href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute) else { return nil }
        if components.path == "/l/", let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return target
        }
        if components.host?.hasSuffix("duckduckgo.com") == true { return nil }
        return absolute
    }

    private static func matches(of pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

/// Just enough HTML-to-text for a model to read a page.
nonisolated enum HTMLText {
    static func plainText(from html: String) -> String {
        var text = html
        // `(?s)` lets `.` span lines, since script and style blocks usually do.
        for pattern in [#"(?s)<(script|style|noscript|template|svg|head|nav|footer|form)\b.*?</\1\s*>"#, #"(?s)<!--.*?-->"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        // Inline tags vanish without a gap, so "<b>actors</b>," stays "actors,".
        text = text.replacingOccurrences(of: #"</?(a|b|strong|em|i|span|code|mark|small|sup|sub|u)\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmed
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return decodeNumericEntities(result)
    }

    /// `&#8217;` and `&#x2019;` style references.
    private static func decodeNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") else { return text }
        var output = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let hex = Range(match.range(at: 1), in: text),
                  let digits = Range(match.range(at: 2), in: text)
            else { continue }
            output += text[cursor..<whole.lowerBound]
            let value = UInt32(text[digits], radix: text[hex].isEmpty ? 10 : 16)
            output += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            cursor = whole.upperBound
        }
        return output + text[cursor...]
    }
}

nonisolated extension URLError {
    /// Failures worth one more try: the connection, not the request, was the problem.
    var isTransient: Bool {
        switch code {
        case .secureConnectionFailed, .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet:
            true
        default:
            false
        }
    }
}
