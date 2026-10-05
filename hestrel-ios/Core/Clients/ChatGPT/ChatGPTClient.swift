import ComposableArchitecture
import Foundation
import CryptoKit

@DependencyClient
nonisolated struct ChatGPTClient: Sendable {
    var session: @Sendable (_ providerID: UUID) async -> ChatGPTSession?
    var signIn: @Sendable (_ providerID: UUID) async throws -> ChatGPTSession
    var signOut: @Sendable (_ providerID: UUID) async throws -> Void
    var accessToken: @Sendable (_ providerID: UUID) async throws -> String
}

nonisolated extension ChatGPTClient: DependencyKey {
    static let liveValue: ChatGPTClient = {
        let sessions = ChatGPTSessionStore()
        return ChatGPTClient(
            session: { await sessions.session($0) },
            signIn: { id in
                let existing = await sessions.session(id)
                let hostID = try await sessions.hostID()
                let registeredClientID = await sessions.registeredClientID(id)
                let session = try await ChatGPTBrowserSignIn().authorize(existing: existing, registeredClientID: registeredClientID, hostID: hostID) { clientID in
                    try await sessions.saveRegistration(clientID, id: id)
                }
                try await sessions.save(session, id: id)
                return session
            },
            signOut: { try await sessions.signOut($0) },
            accessToken: { try await sessions.accessToken($0) }
        )
    }()
    static let testValue = ChatGPTClient()
}

nonisolated extension DependencyValues {
    var chatGPT: ChatGPTClient {
        get { self[ChatGPTClient.self] }
        set { self[ChatGPTClient.self] = newValue }
    }
}

actor ChatGPTSessionStore {
    private let credentials = CredentialsClient.liveValue
    private var refreshes: [UUID: Task<ChatGPTSession, any Error>] = [:]
    private static let hostKey = UUID(uuidString: "718F1292-B124-4CD9-9CA6-448E9DB86745")!

    private func registrationKey(_ id: UUID) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((id.uuidString + ":chatgpt-registration").utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func registeredClientID(_ id: UUID) -> String? {
        credentials.secret(id: registrationKey(id))
    }

    func saveRegistration(_ clientID: String, id: UUID) throws {
        let key = registrationKey(id)
        credentials.setSecret(value: clientID, id: key)
        guard credentials.secret(id: key) == clientID else { throw ChatGPTError.invalidIdentity }
    }

    func session(_ id: UUID) -> ChatGPTSession? {
        guard let stored = credentials.secret(id: id) else { return nil }
        return try? JSONDecoder().decode(ChatGPTSession.self, from: Data(stored.utf8))
    }

    func save(_ session: ChatGPTSession, id: UUID) throws {
        let value = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        credentials.setSecret(value: value, id: id)
        guard credentials.secret(id: id) == value else {
            throw ChatGPTError.message("Could not securely save your ChatGPT connection. Please try again.")
        }
    }

    func hostID() throws -> String {
        if let saved = credentials.secret(id: Self.hostKey) { return saved }
        let value = "urn:uuid:" + UUID().uuidString.lowercased()
        credentials.setSecret(value: value, id: Self.hostKey)
        guard credentials.secret(id: Self.hostKey) == value else { throw ChatGPTError.invalidIdentity }
        return value
    }

    func accessToken(_ id: UUID) async throws -> String {
        guard let saved = session(id), saved.isConnected else { throw ChatGPTError.signInRequired }
        if saved.expiresAt > Date().addingTimeInterval(60), let token = saved.accessToken { return token }
        if let task = refreshes[id] { return try await task.value.accessToken! }
        guard let refreshToken = saved.refreshToken else { throw ChatGPTError.signInRequired }
        let task = Task {
            let tokens = try await ChatGPTOAuth.token([
                "grant_type": "refresh_token", "client_id": saved.clientID,
                "refresh_token": refreshToken, "resource": ChatGPTOAuth.resource,
            ])
            try Task.checkCancellation()
            var updated = saved
            updated.accessToken = tokens.access_token
            updated.refreshToken = tokens.refresh_token ?? saved.refreshToken
            updated.expiresAt = Date().addingTimeInterval(tokens.expires_in)
            if let scope = tokens.scope { updated.scopes = scope.split(separator: " ").map(String.init) }
            guard updated.isConnected else { throw ChatGPTError.signInRequired }
            try self.save(updated, id: id)
            return updated
        }
        refreshes[id] = task
        defer { refreshes[id] = nil }
        return try await task.value.accessToken!
    }

    func signOut(_ id: UUID) async throws {
        refreshes[id]?.cancel()
        if let task = refreshes[id] { _ = try? await task.value }
        guard var saved = session(id) else { return }
        var revocationFailed = false
        if let refreshToken = saved.refreshToken {
            do {
                struct Discovery: Decodable { var revocation_endpoint: URL }
                let (data, response) = try await URLSession.shared.data(from: URL(string: ChatGPTOAuth.issuer + "/.well-known/openid-configuration")!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTError.invalidIdentity }
                let discovery = try JSONDecoder().decode(Discovery.self, from: data)
                guard discovery.revocation_endpoint.scheme == "https", discovery.revocation_endpoint.host == "auth.openai.com" else { throw ChatGPTError.invalidIdentity }
                _ = try await ChatGPTOAuth.post(discovery.revocation_endpoint, fields: [
                    "token": refreshToken, "token_type_hint": "refresh_token", "client_id": saved.clientID,
                ])
            } catch { revocationFailed = true }
        }
        saved.accessToken = nil
        saved.refreshToken = nil
        saved.idToken = nil
        try save(saved, id: id)
        if revocationFailed {
            throw ChatGPTError.message("Signed out on this device. Remote revocation could not be confirmed; disconnect Hestrel in ChatGPT Settings → Usage.")
        }
    }
}
