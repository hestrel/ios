import ComposableArchitecture
import Foundation

/// The Hestrel accounts and sync API (see the `hestrel/cloudflare` repository).
@DependencyClient
nonisolated struct HestrelAPIClient: Sendable {
    var signInWithApple: @Sendable (_ identityToken: String, _ nonce: String) async throws -> SignInResponse
    var signOut: @Sendable (_ token: String) async throws -> Void
    var deleteAccount: @Sendable (_ token: String, _ authorizationCode: String?) async throws -> Void
    var push: @Sendable (_ token: String, _ changes: [SyncChange]) async throws -> PushResponse
    var pull: @Sendable (_ token: String, _ cursor: Int) async throws -> PullResponse
    /// Computers paired with the account, whose coding agents its devices reach through the relay.
    var listComputers: @Sendable (_ token: String) async throws -> [Computer]
    var claimComputer: @Sendable (_ token: String, _ code: String) async throws -> Computer
    var removeComputer: @Sendable (_ token: String, _ id: Computer.ID) async throws -> Void
}

nonisolated struct SignInResponse: Decodable, Sendable {
    let token: String
    let user: Account
}

nonisolated enum HestrelAPIError: LocalizedError, Equatable {
    /// The session expired or was revoked; the user has to sign in again.
    case unauthorized
    case server(status: Int, message: String?)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "You were signed out. Sign in again to keep syncing."
        case let .server(status, message): message ?? "The sync server responded with an error (\(status))."
        case .unexpectedResponse: "The sync server sent an unexpected response."
        }
    }
}

nonisolated extension HestrelAPIClient: DependencyKey {
    static let baseURL: URL = {
        #if DEBUG
        // Points a development build at a local `wrangler dev`, e.g. HESTREL_API_URL=http://127.0.0.1:8787/.
        if let override = ProcessInfo.processInfo.environment["HESTREL_API_URL"].flatMap(URL.init(string:)) {
            return override
        }
        #endif
        return URL(string: "https://hestrel-api.hestrel-cloud.workers.dev/")!
    }()

    static let liveValue: HestrelAPIClient = {
        @Sendable func send(
            _ method: String,
            _ path: String,
            token: String? = nil,
            body: (any Encodable)? = nil
        ) async throws -> Data {
            guard let url = URL(string: path, relativeTo: baseURL) else { throw HestrelAPIError.unexpectedResponse }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = method
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HestrelAPIError.unexpectedResponse }
            switch http.statusCode {
            case 200..<300:
                return data
            case 401:
                throw HestrelAPIError.unauthorized
            default:
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                throw HestrelAPIError.server(status: http.statusCode, message: message)
            }
        }

        @Sendable func decode<Response: Decodable>(_: Response.Type, from data: Data) throws -> Response {
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw HestrelAPIError.unexpectedResponse
            }
        }

        return HestrelAPIClient(
            signInWithApple: { identityToken, nonce in
                let data = try await send("POST", "v1/auth/apple", body: ["identityToken": identityToken, "nonce": nonce])
                return try decode(SignInResponse.self, from: data)
            },
            signOut: { token in
                _ = try await send("POST", "v1/auth/logout", token: token)
            },
            deleteAccount: { token, authorizationCode in
                _ = try await send("DELETE", "v1/account", token: token, body: ["authorizationCode": authorizationCode])
            },
            push: { token, changes in
                let data = try await send("POST", "v1/sync/push", token: token, body: ["changes": changes])
                return try decode(PushResponse.self, from: data)
            },
            pull: { token, cursor in
                let data = try await send("GET", "v1/sync/pull?cursor=\(cursor)&limit=\(pullPageSize)", token: token)
                return try decode(PullResponse.self, from: data)
            },
            listComputers: { token in
                struct Response: Decodable { let computers: [Computer] }
                return try decode(Response.self, from: try await send("GET", "v1/computers", token: token)).computers
            },
            claimComputer: { token, code in
                try decode(Computer.self, from: try await send("POST", "v1/computers/claim", token: token, body: ["code": code]))
            },
            removeComputer: { token, id in
                _ = try await send("DELETE", "v1/computers/\(id.uuidString.lowercased())", token: token)
            }
        )
    }()

    static let testValue = HestrelAPIClient()

    static let pullPageSize = 200

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

nonisolated extension DependencyValues {
    var hestrelAPI: HestrelAPIClient {
        get { self[HestrelAPIClient.self] }
        set { self[HestrelAPIClient.self] = newValue }
    }
}
