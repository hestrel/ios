import AuthenticationServices
import CryptoKit
import Network
import UIKit

/// Keeps the app active in a system authentication session while receiving OpenAI's loopback callback.
@MainActor
final class ChatGPTBrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var anchor: UIWindow?
    private var browser: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var callbackURL: URL?
    private var connections: [NWConnection] = []

    func authorize(existing: ChatGPTSession?, registeredClientID: String?, hostID: String,
                   onRegistration: @Sendable (String) async throws -> Void) async throws -> ChatGPTSession {
        let existingClientID = existing?.clientID ?? registeredClientID
        guard let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw ChatGPTError.message("Open Hestrel before starting ChatGPT sign-in.")
        }
        self.anchor = anchor
        let state = try ChatGPTOAuth.random()
        let nonce = try ChatGPTOAuth.random()
        let verifier = try ChatGPTOAuth.random()
        expectedState = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer { cleanup() }
        let callback = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                self.continuation = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard let port = listener.port else { self.finish(.failure(ChatGPTError.invalidIdentity)); return }
                            let callbackURL = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                            self.callbackURL = callbackURL
                            var url = URLComponents(string: ChatGPTOAuth.issuer + "/api/accounts/authorize")!
                            var fields = [
                                "client_id": existingClientID ?? "dynamic_agent_client",
                                "ext_agent_host_id": hostID,
                                "response_type": "code", "redirect_uri": callbackURL.absoluteString,
                                "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                                "resource": ChatGPTOAuth.resource, "state": state, "nonce": nonce,
                                "code_challenge_method": "S256",
                                "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL,
                            ]
                            if existingClientID == nil { fields["agent_name_hint"] = "Hestrel" }
                            if let hint = existing?.idToken { fields["id_token_hint"] = hint }
                            url.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
                            let browser = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: nil) { [weak self] _, error in
                                Task { @MainActor [weak self] in
                                    self?.finish(.failure(error ?? CancellationError()))
                                }
                            }
                            browser.presentationContextProvider = self
                            self.browser = browser
                            if !browser.start() { self.finish(.failure(ChatGPTError.message("Could not open ChatGPT sign-in."))) }
                        case let .failed(error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        guard let self else { connection.cancel(); return }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.receive(connection, buffer: Data())
                    }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.finish(.failure(ChatGPTError.message("ChatGPT sign-in timed out. Please try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        // Close the browser before token exchange; the callback has already been validated.
        cleanup()
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard value("error") == nil else { throw ChatGPTError.message("ChatGPT sign-in was declined. You can try again when ready.") }
        guard let code = value("code"), !code.isEmpty, let callbackURL else { throw ChatGPTError.invalidIdentity }
        let clientID = value("client_id") ?? existingClientID
        guard let clientID, clientID != "dynamic_agent_client", !clientID.isEmpty,
              existingClientID == nil || existingClientID == clientID else { throw ChatGPTError.invalidIdentity }
        try await onRegistration(clientID)
        let tokens = try await ChatGPTOAuth.token([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": callbackURL.absoluteString, "resource": ChatGPTOAuth.resource,
        ])
        guard let idToken = tokens.id_token else { throw ChatGPTError.invalidIdentity }
        let identity = try await ChatGPTOAuth.validate(idToken, clientID: clientID, nonce: nonce)
        guard existing == nil || existing?.subject == identity.sub else { throw ChatGPTError.invalidIdentity }
        let scopes = (tokens.scope ?? "").split(separator: " ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct") else {
            throw ChatGPTError.message("ChatGPT plan usage was not enabled. Please reconnect and allow Hestrel to use your plan.")
        }
        return ChatGPTSession(clientID: clientID, subject: identity.sub, email: identity.email,
                              accessToken: tokens.access_token, refreshToken: tokens.refresh_token, idToken: idToken,
                              expiresAt: Date().addingTimeInterval(tokens.expires_in), scopes: scopes)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                let buffer = buffer + (data ?? Data())
                guard error == nil, buffer.count <= 16_384 else { connection.cancel(); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let line = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                guard line.count == 3, line[0] == "GET", line[1].hasPrefix("/auth/callback?"),
                      let url = URL(string: String(line[1]), relativeTo: self.callbackURL)?.absoluteURL,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      components.queryItems?.filter({ $0.name == "state" }).count == 1,
                      components.queryItems?.first(where: { $0.name == "state" })?.value == self.expectedState else {
                    self.respond(connection, status: "400 Bad Request", body: "Invalid callback.")
                    return
                }
                self.respond(connection, status: "200 OK", body: "Returning to Hestrel. You may close this page.")
                self.finish(.success(url))
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func cleanup() {
        timeout?.cancel()
        listener?.cancel()
        browser?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        browser = nil
        listener = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Captured before starting the authentication session.
        anchor!
    }
}
