import Foundation

nonisolated enum LLMError: LocalizedError, Equatable {
    case invalidBaseURL(String)
    case missingAPIKey(provider: String)
    case http(status: Int, message: String?)
    case server(String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            "“\(url)” isn’t a valid server address."
        case let .missingAPIKey(provider):
            "\(provider) needs an API key. Add one in Settings."
        case let .http(status, message):
            "Request failed (\(status)). \(message ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        case let .server(message):
            message
        case .unexpectedResponse:
            "The server returned an unexpected response."
        }
    }

    /// Extracts a human-readable message from the error payloads used by OpenAI, Anthropic and Ollama.
    static func serverMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data.prefix(500), as: UTF8.self).nonBlank
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return (object["error"] as? String) ?? (object["message"] as? String)
    }
}
