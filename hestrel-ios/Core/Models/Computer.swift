import Foundation

/// A computer running Hestrel's bridge, paired with the account. Every device signed in to the account
/// reaches its coding agents through Hestrel's relay, from anywhere.
nonisolated struct Computer: Decodable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    /// The IDs of the agents its bridge offers.
    let agents: [String]
    let online: Bool
    /// Milliseconds since 1970, when the bridge last connected or disconnected.
    let lastSeenAt: Double?

    var lastSeen: Date? { lastSeenAt.map { Date(timeIntervalSince1970: $0 / 1_000) } }

    /// The computer's MCP endpoint on the relay.
    var relayURL: URL {
        HestrelAPIClient.baseURL.appending(path: "v1/computers/\(id.uuidString.lowercased())/mcp")
    }
}

nonisolated extension MCPServer {
    /// The server for a paired computer, which shares the computer's ID. Its tools work with every provider.
    static func computer(_ computer: Computer, isEnabled: Bool = true) -> MCPServer {
        MCPServer(id: computer.id, providerID: nil, name: computer.name, url: computer.relayURL.absoluteString, isEnabled: isEnabled, origin: .computer)
    }
}

/// `hestrel://pair?code=K7Q2M9XD`, shown by the bridge as a QR code.
nonisolated enum PairingLink {
    /// The pairing code in a scanned link, or a code typed by hand like "K7Q2-M9XD".
    static func code(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "hestrel" {
            guard url.host()?.lowercased() == "pair" else { return nil }
            let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
            return code.flatMap(normalized)
        }
        return normalized(trimmed)
    }

    /// Eight letters and digits; separators and case don't matter.
    private static func normalized(_ code: String) -> String? {
        let characters = code.uppercased().filter { $0.isLetter || $0.isNumber }
        return characters.count == 8 && characters.allSatisfy(\.isASCII) ? characters : nil
    }
}
