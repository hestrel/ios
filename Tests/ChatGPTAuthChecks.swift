import Foundation
import Security

@main
struct ChatGPTAuthChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = ChatGPTOAuth.Identity(iss: ChatGPTOAuth.issuer, sub: "user-1", aud: .values(["hestrel-client"]),
                                         exp: now.timeIntervalSince1970 + 3600, iat: now.timeIntervalSince1970,
                                         nonce: "attempt-nonce", email: nil)
        try ChatGPTOAuth.validateClaims(valid, clientID: "hestrel-client", nonce: "attempt-nonce", now: now)
        var checks = 1
        func reject(_ label: String, _ mutate: (inout ChatGPTOAuth.Identity) -> Void) throws {
            var identity = valid
            mutate(&identity)
            do {
                try ChatGPTOAuth.validateClaims(identity, clientID: "hestrel-client", nonce: "attempt-nonce", now: now)
                fatalError("Accepted invalid \(label)")
            } catch { checks += 1 }
        }
        try reject("issuer") { $0.iss = "https://example.com" }
        try reject("audience") { $0.aud = .values(["other-client"]) }
        try reject("nonce") { $0.nonce = "other-attempt" }
        try reject("missing nonce") { $0.nonce = nil }
        try reject("expiration") { $0.exp = now.timeIntervalSince1970 - 10 }
        try reject("future issuance") { $0.iat = now.timeIntervalSince1970 + 60 }
        try reject("empty subject") { $0.sub = "" }
        let random = try ChatGPTOAuth.random()
        guard let bytes = Data(base64URL: random), bytes.count == 32, bytes.base64URL == random else {
            fatalError("Invalid PKCE entropy or encoding")
        }
        checks += 1
        let disconnected = ChatGPTSession(clientID: "client", subject: "user", accessToken: "token",
                                         expiresAt: now, scopes: ["openid"])
        precondition(!disconnected.isConnected, "Identity scopes must not enable inference")
        checks += 1
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
        let publicKey = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data
        let message = Data("header.claims".utf8)
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
        try ChatGPTOAuth.verifySignature(publicKeyDER: publicKey, message: message, signature: signature)
        checks += 1
        do {
            try ChatGPTOAuth.verifySignature(publicKeyDER: publicKey, message: Data("header.tampered".utf8), signature: signature)
            fatalError("Accepted tampered signed identity")
        } catch { checks += 1 }
        print("Passed \(checks) ChatGPT authentication checks.")
    }
}
