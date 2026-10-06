import CryptoKit
import Foundation

/// A signed-in OAuth session with an MCP server, stored as JSON in the Keychain.
nonisolated struct MCPOAuthSession: Codable, Equatable, Sendable {
    var clientID: String
    var tokenEndpoint: URL
    /// The MCP server URL the tokens are bound to (RFC 8707 `resource`).
    var resource: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    func needsRefresh(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

nonisolated enum MCPOAuthError: LocalizedError, Equatable {
    case discoveryFailed
    case registrationUnsupported
    case server(String)
    case invalidCallback
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed: "This server doesn’t advertise how to sign in."
        case .registrationUnsupported: "This server doesn’t let new apps register. Add it manually with an access token."
        case let .server(message): message
        case .invalidCallback: "Sign-in returned an unexpected response. Please try again."
        case let .denied(reason): "Sign-in was declined (\(reason))."
        }
    }
}

/// The MCP authorization flow (OAuth 2.1): protected-resource discovery, authorization-server
/// metadata, dynamic client registration, PKCE, and token refresh.
///
/// The redirect is a loopback address (RFC 8252): several services reject custom URL schemes
/// such as `hestrel://`, while every one in the directory accepts `http://127.0.0.1:<port>`.
nonisolated enum MCPOAuth {
    struct ServerMetadata: Equatable, Sendable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let registrationEndpoint: URL?
        let scopes: [String]
    }

    /// A prepared authorization request: the page to open and what's needed to finish afterwards.
    struct Authorization: Sendable {
        let url: URL
        let state: String
        let verifier: String
        let clientID: String
        let metadata: ServerMetadata
        let resource: String
        let redirectURI: String
    }

    // MARK: Discovery

    static func discover(serverURL: URL) async throws -> ServerMetadata {
        let resource = try? await protectedResource(for: serverURL)
        let issuer = resource?.authorizationServers.first.flatMap(URL.init(string:))
            ?? URL(string: "\(serverURL.scheme ?? "https")://\(serverURL.host() ?? "")")!

        for candidate in metadataURLs(for: issuer) {
            guard let document = try? await getJSON(candidate) else { continue }
            guard let authorization = document["authorization_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                  let token = document["token_endpoint"]?.stringValue.flatMap(URL.init(string:))
            else { continue }
            let scopes = (resource?.scopes ?? document["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)) ?? []
            return ServerMetadata(
                authorizationEndpoint: authorization,
                tokenEndpoint: token,
                registrationEndpoint: document["registration_endpoint"]?.stringValue.flatMap(URL.init(string:)),
                scopes: scopes
            )
        }
        throw MCPOAuthError.discoveryFailed
    }

    private struct ProtectedResource {
        let authorizationServers: [String]
        let scopes: [String]?
    }

    /// RFC 9728 metadata, tried at the path-specific location first.
    private static func protectedResource(for serverURL: URL) async throws -> ProtectedResource {
        let origin = "\(serverURL.scheme ?? "https")://\(serverURL.host() ?? "")\(serverURL.port.map { ":\($0)" } ?? "")"
        let path = serverURL.path()
        let candidates = [path.isEmpty || path == "/" ? nil : "\(origin)/.well-known/oauth-protected-resource\(path)",
                          "\(origin)/.well-known/oauth-protected-resource"].compactMap { $0.flatMap(URL.init(string:)) }
        for candidate in candidates {
            if let document = try? await getJSON(candidate),
               let servers = document["authorization_servers"]?.arrayValue?.compactMap(\.stringValue), !servers.isEmpty {
                return ProtectedResource(
                    authorizationServers: servers,
                    scopes: document["scopes_supported"]?.arrayValue?.compactMap(\.stringValue)
                )
            }
        }
        throw MCPOAuthError.discoveryFailed
    }

    /// RFC 8414 and OpenID locations, with the issuer's path inserted after `.well-known` first.
    private static func metadataURLs(for issuer: URL) -> [URL] {
        let origin = "\(issuer.scheme ?? "https")://\(issuer.host() ?? "")\(issuer.port.map { ":\($0)" } ?? "")"
        var path = issuer.path()
        while path.hasSuffix("/") { path.removeLast() }
        return [
            "\(origin)/.well-known/oauth-authorization-server\(path)",
            "\(origin)\(path)/.well-known/oauth-authorization-server",
            "\(origin)/.well-known/openid-configuration\(path)",
            "\(origin)\(path)/.well-known/openid-configuration",
        ].compactMap(URL.init(string:))
    }

    // MARK: Authorization

    static func register(at endpoint: URL, redirectURI: String) async throws -> String {
        let body: JSONValue = .object([
            "client_name": .string("Hestrel"),
            "redirect_uris": .array([.string(redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ])
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let document = try await sendJSON(request)
        guard let clientID = document["client_id"]?.stringValue else {
            throw MCPOAuthError.server("The server didn’t return a client ID.")
        }
        return clientID
    }

    static func prepareAuthorization(serverURL: URL, redirectURI: String) async throws -> Authorization {
        let metadata = try await discover(serverURL: serverURL)
        guard let registration = metadata.registrationEndpoint else { throw MCPOAuthError.registrationUnsupported }
        let clientID = try await register(at: registration, redirectURI: redirectURI)

        let verifier = randomToken()
        let state = randomToken()
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: serverURL.absoluteString),
        ]
        if !metadata.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: metadata.scopes.joined(separator: " ")))
        }
        components.queryItems = items
        guard let url = components.url else { throw MCPOAuthError.discoveryFailed }
        return Authorization(url: url, state: state, verifier: verifier, clientID: clientID, metadata: metadata,
                             resource: serverURL.absoluteString, redirectURI: redirectURI)
    }

    /// Trades the callback's authorization code for tokens.
    static func finish(_ authorization: Authorization, callback: URL, now: Date) async throws -> MCPOAuthSession {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw MCPOAuthError.denied(value("error_description") ?? error) }
        guard value("state") == authorization.state, let code = value("code") else { throw MCPOAuthError.invalidCallback }

        let tokens = try await tokenRequest(authorization.metadata.tokenEndpoint, fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": authorization.redirectURI,
            "client_id": authorization.clientID,
            "code_verifier": authorization.verifier,
            "resource": authorization.resource,
        ])
        return try session(from: tokens, clientID: authorization.clientID, tokenEndpoint: authorization.metadata.tokenEndpoint,
                           resource: authorization.resource, previousRefreshToken: nil, now: now)
    }

    static func refresh(_ session: MCPOAuthSession, now: Date) async throws -> MCPOAuthSession {
        guard let refreshToken = session.refreshToken else { return session }
        let tokens = try await tokenRequest(session.tokenEndpoint, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": session.clientID,
            "resource": session.resource,
        ])
        return try self.session(from: tokens, clientID: session.clientID, tokenEndpoint: session.tokenEndpoint,
                                resource: session.resource, previousRefreshToken: refreshToken, now: now)
    }

    private static func session(
        from tokens: JSONValue,
        clientID: String,
        tokenEndpoint: URL,
        resource: String,
        previousRefreshToken: String?,
        now: Date
    ) throws -> MCPOAuthSession {
        guard let accessToken = tokens["access_token"]?.stringValue else {
            throw MCPOAuthError.server("The server didn’t return an access token.")
        }
        let expiresIn: Double? = switch tokens["expires_in"] {
        case let .number(seconds)?: seconds
        case let .string(seconds)?: Double(seconds)
        default: nil
        }
        return MCPOAuthSession(
            clientID: clientID,
            tokenEndpoint: tokenEndpoint,
            resource: resource,
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"]?.stringValue ?? previousRefreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) }
        )
    }

    // MARK: HTTP

    private static func tokenRequest(_ endpoint: URL, fields: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        return try await sendJSON(request)
    }

    private static func getJSON(_ url: URL) async throws -> JSONValue {
        try await sendJSON(URLRequest(url: url, timeoutInterval: 15))
    }

    private static func sendJSON(_ request: URLRequest) async throws -> JSONValue {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Hestrel/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let document = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = document?["error_description"]?.stringValue ?? document?["error"]?.stringValue
            throw MCPOAuthError.server(message ?? "The sign-in server returned an error.")
        }
        guard let document else { throw MCPOAuthError.server("The sign-in server returned an unexpected response.") }
        return document
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URL
    }
}
