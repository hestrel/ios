import AuthenticationServices
import ComposableArchitecture
import Foundation
import Network
import UIKit

/// Signs in to MCP servers and supplies the headers each request needs.
///
/// A server's Keychain slot holds either a plain bearer token or an `MCPOAuthSession` as JSON;
/// OAuth sessions are refreshed here shortly before they expire.
@DependencyClient
nonisolated struct MCPAuthClient: Sendable {
    /// Runs the OAuth sign-in in the system browser and stores the session.
    var signIn: @Sendable (_ server: MCPServer) async throws -> Void
    var headers: @Sendable (_ server: MCPServer) async throws -> [String: String]
    var signOut: @Sendable (_ server: MCPServer) async -> Void
}

nonisolated extension MCPAuthClient: DependencyKey {
    static let liveValue: MCPAuthClient = {
        let store = MCPCredentialStore()
        return MCPAuthClient(
            signIn: { server in
                guard let url = URL(string: server.url.trimmed) else { throw MCPError.invalidURL(server.url) }
                let (authorization, callback) = try await LoopbackSignIn.run { redirectURI in
                    try await MCPOAuth.prepareAuthorization(serverURL: url, redirectURI: redirectURI)
                }
                let session = try await MCPOAuth.finish(authorization, callback: callback, now: Date())
                await store.save(session, for: server.id)
            },
            headers: { server in
                // The relay checks that the computer belongs to the signed-in account.
                if server.origin == .computer {
                    return server.authHeaders(token: CredentialsClient.liveValue.secret(id: Account.sessionTokenID))
                }
                return try await server.authHeaders(token: store.bearerToken(for: server.id))
            },
            signOut: { server in
                await store.remove(server.id)
            }
        )
    }()

    static let testValue = MCPAuthClient()
}

nonisolated extension DependencyValues {
    var mcpAuth: MCPAuthClient {
        get { self[MCPAuthClient.self] }
        set { self[MCPAuthClient.self] = newValue }
    }
}

/// Keychain-backed MCP credentials, refreshing each OAuth session at most once at a time.
private actor MCPCredentialStore {
    private let credentials = CredentialsClient.liveValue
    private var refreshes: [MCPServer.ID: Task<MCPOAuthSession, any Error>] = [:]

    func save(_ session: MCPOAuthSession, for serverID: MCPServer.ID) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        credentials.setSecret(value: String(decoding: data, as: UTF8.self), id: serverID)
    }

    func remove(_ serverID: MCPServer.ID) {
        refreshes[serverID]?.cancel()
        credentials.setSecret(value: nil, id: serverID)
    }

    func bearerToken(for serverID: MCPServer.ID) async throws -> String? {
        guard let stored = credentials.secret(id: serverID) else { return nil }
        guard let session = try? JSONDecoder().decode(MCPOAuthSession.self, from: Data(stored.utf8)) else {
            return stored // A plain token added by hand.
        }
        guard session.needsRefresh(now: Date()) else { return session.accessToken }

        if let refresh = refreshes[serverID] { return try await refresh.value.accessToken }
        let refresh = Task { try await MCPOAuth.refresh(session, now: Date()) }
        refreshes[serverID] = refresh
        defer { refreshes[serverID] = nil }
        let refreshed = try await refresh.value
        save(refreshed, for: serverID)
        return refreshed.accessToken
    }
}

/// Runs a browser sign-in whose redirect lands on a short-lived listener at `http://127.0.0.1:<port>`.
@MainActor
private final class LoopbackSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static var current: LoopbackSignIn?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var browser: ASWebAuthenticationSession?
    private var callback: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?

    /// Starts the listener, lets `prepare` register for its redirect URI, opens the sign-in page and
    /// waits for the redirect.
    static func run(
        prepare: @Sendable (String) async throws -> MCPOAuth.Authorization
    ) async throws -> (MCPOAuth.Authorization, URL) {
        let runner = LoopbackSignIn()
        current = runner
        defer {
            runner.cleanup()
            current = nil
        }
        let port = try await runner.startListener()
        let authorization = try await prepare("http://127.0.0.1:\(port)/callback")
        let callback = try await withCheckedThrowingContinuation { continuation in
            runner.callback = continuation
            runner.openBrowser(authorization.url)
        }
        return (authorization, callback)
    }

    private func startListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockIsolated(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !resumed.value, let port = listener.port?.rawValue else { return }
                    resumed.setValue(true)
                    continuation.resume(returning: port)
                case let .failed(error):
                    guard !resumed.value else { return }
                    resumed.setValue(true)
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func openBrowser(_ url: URL) {
        let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor [weak self] in self?.finish(.failure(error ?? MCPOAuthError.invalidCallback)) }
        }
        browser.presentationContextProvider = self
        self.browser = browser
        if !browser.start() {
            finish(.failure(MCPOAuthError.server("Couldn’t open the sign-in page.")))
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(MCPOAuthError.server("Sign-in timed out. Please try again.")))
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in self?.handle(data ?? Data(), on: connection) }
        }
    }

    /// Answers `GET /callback?…` and hands its URL to the waiting sign-in; anything else gets a 404.
    private func handle(_ data: Data, on connection: NWConnection) {
        let requestLine = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1].hasPrefix("/callback"),
              let port = listener?.port?.rawValue,
              let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])")
        else {
            respond(on: connection, status: "404 Not Found", body: "Not found.")
            return
        }
        respond(on: connection, status: "200 OK", body: "Signed in. You can return to Hestrel.")
        finish(.success(url))
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta name=viewport content=\"width=device-width\"><body style=\"font:17px -apple-system;text-align:center;padding-top:30vh\">\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let callback else { return }
        self.callback = nil
        callback.resume(with: result)
    }

    private func cleanup() {
        timeout?.cancel()
        browser?.cancel()
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor(windowScene: scenes[0])
    }
}

nonisolated extension Error {
    /// The user closed the sign-in sheet.
    var isWebAuthenticationCancellation: Bool {
        (self as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
