import Foundation
import CryptoKit
import Security

nonisolated struct ChatGPTSession: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String?
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]

    var isConnected: Bool { accessToken != nil && scopes.contains("chatgpt.tokens.use.direct") }
}

nonisolated enum ChatGPTError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(message): message }
    }
    static let signInRequired = Self.message("Continue with ChatGPT in the OpenAI provider settings to connect your plan.")
    static let invalidIdentity = Self.message("ChatGPT returned an invalid sign-in response. Please try again.")
}

nonisolated enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"

    struct Tokens: Decodable, Sendable {
        var access_token: String
        var refresh_token: String?
        var id_token: String?
        var expires_in: Double
        var scope: String?
        var token_type: String
    }

    static func token(_ fields: [String: String]) async throws -> Tokens {
        let data = try await post(URL(string: issuer + "/api/accounts/oauth/token")!, fields: fields)
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard tokens.token_type.lowercased() == "bearer", !tokens.access_token.isEmpty, tokens.expires_in > 0 else {
            throw ChatGPTError.invalidIdentity
        }
        return tokens
    }

    static func post(_ url: URL, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTError.message("ChatGPT authorization could not be completed. Please sign in again.")
        }
        return data
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTError.invalidIdentity
        }
        return Data(bytes).base64URL
    }

    struct Identity: Decodable, Sendable {
        var iss: String
        var sub: String
        var aud: Audience
        var exp: Double
        var iat: Double
        var nonce: String?
        var email: String?
    }

    enum Audience: Decodable, Sendable {
        case values([String])
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .values([value]) }
            else { self = .values(try container.decode([String].self)) }
        }
        func contains(_ value: String) -> Bool {
            switch self { case let .values(values): values.contains(value) }
        }
    }

    static func validate(_ jwt: String, clientID: String, nonce: String) async throws -> Identity {
        struct Header: Decodable { var alg: String; var kid: String }
        struct Key: Decodable { var kty: String; var kid: String; var n: String?; var e: String? }
        struct Keys: Decodable { var keys: [Key] }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(base64URL: parts[0]), let claimsData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]) else { throw ChatGPTError.invalidIdentity }
        let header = try JSONDecoder().decode(Header.self, from: headerData)
        guard header.alg == "RS256" else { throw ChatGPTError.invalidIdentity }
        let (data, response) = try await URLSession.shared.data(from: URL(string: issuer + "/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTError.invalidIdentity }
        let keys = try JSONDecoder().decode(Keys.self, from: data)
        guard let key = keys.keys.first(where: { $0.kid == header.kid && $0.kty == "RSA" }),
              let n = key.n.flatMap({ Data(base64URL: $0) }), let e = key.e.flatMap({ Data(base64URL: $0) })
        else { throw ChatGPTError.invalidIdentity }
        let der = asn1(0x30, integer(n) + integer(e))
        try verifySignature(publicKeyDER: der, message: Data((parts[0] + "." + parts[1]).utf8), signature: signature)
        let identity = try JSONDecoder().decode(Identity.self, from: claimsData)
        try validateClaims(identity, clientID: clientID, nonce: nonce)
        return identity
    }

    static func verifySignature(publicKeyDER: Data, message: Data, signature: Data) throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(publicKeyDER as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    message as CFData, signature as CFData, nil)
        else { throw ChatGPTError.invalidIdentity }
    }

    static func validateClaims(_ identity: Identity, clientID: String, nonce: String, now: Date = Date()) throws {
        guard identity.iss == issuer, identity.aud.contains(clientID), !identity.sub.isEmpty,
              identity.exp > now.timeIntervalSince1970 - 5, identity.iat <= now.timeIntervalSince1970 + 5,
              identity.nonce == nonce else { throw ChatGPTError.invalidIdentity }
    }

    private static func integer(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! >= 128 { bytes.insert(0, at: 0) }
        return asn1(0x02, bytes)
    }

    private static func asn1(_ tag: UInt8, _ bytes: Data) -> Data {
        var count = bytes.count
        var length: [UInt8] = []
        repeat { length.insert(UInt8(count & 255), at: 0); count >>= 8 } while count > 0
        return Data([tag] + (bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(length.count)] + length)) + bytes
    }
}

nonisolated extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let string = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: string + String(repeating: "=", count: (4 - string.count % 4) % 4))
    }
}
