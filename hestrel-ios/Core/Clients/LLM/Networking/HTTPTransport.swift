import Foundation

/// The outcome of parsing one line of a streaming response body.
nonisolated struct StreamLine: Sendable {
    var events: [ChatStreamEvent] = []
    var isFinal = false

    static let skip = StreamLine()
    static let final = StreamLine(isFinal: true)
}

/// Turns the lines of a streaming response into chat events.
///
/// Parsers are stateful because tool calls arrive in fragments spread across many lines.
nonisolated protocol StreamParser {
    mutating func parse(_ line: String) throws -> StreamLine
    /// Events still buffered when the stream ends.
    mutating func finish() -> [ChatStreamEvent]
}

nonisolated extension StreamParser {
    mutating func finish() -> [ChatStreamEvent] { [] }
}

nonisolated struct HTTPTransport: Sendable {
    var session: URLSession = .shared

    func json<Response: Decodable>(_: Response.Type, for request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, body: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMError.unexpectedResponse
        }
    }

    /// Streams a line-delimited response (SSE or NDJSON) through `parser`.
    func stream(
        _ request: URLRequest,
        parser: some StreamParser & Sendable
    ) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = parser
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes.prefix(64_000) { body.append(byte) }
                        try Self.validate(response, body: body)
                    }
                    for try await line in bytes.lines {
                        let parsed = try parser.parse(line)
                        parsed.events.forEach { continuation.yield($0) }
                        if parsed.isFinal { break }
                    }
                    parser.finish().forEach { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, message: LLMError.serverMessage(from: body))
        }
    }
}

nonisolated enum Endpoint {
    static func url(_ baseURL: String, _ path: String = "") throws -> URL {
        var base = baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        let string = path.isEmpty ? base : "\(base)/\(path)"
        guard let url = URL(string: string),
              ["http", "https"].contains(url.scheme ?? ""),
              url.host() != nil
        else { throw LLMError.invalidBaseURL(baseURL) }
        return url
    }
}

nonisolated enum ServerSentEvents {
    /// The payload of an SSE `data:` line, or `nil` for any other kind of line.
    static func data(in line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmed
    }
}

nonisolated extension URLRequest {
    init(url: URL, method: String = "GET", headers: [String: String], timeout: TimeInterval = 30) {
        self.init(url: url, timeoutInterval: timeout)
        httpMethod = method
        for (field, value) in headers {
            setValue(value, forHTTPHeaderField: field)
        }
    }

    static func post(
        _ url: URL,
        body: some Encodable,
        headers: [String: String],
        timeout: TimeInterval = 300
    ) throws -> URLRequest {
        var request = URLRequest(url: url, method: "POST", headers: headers, timeout: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}
