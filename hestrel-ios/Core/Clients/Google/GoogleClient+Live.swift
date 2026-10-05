import ComposableArchitecture
import Foundation
import GoogleSignIn
import UIKit

nonisolated extension GoogleClient: DependencyKey {
    static let liveValue = GoogleClient(
        restore: { try await GoogleAccountSession.shared.restore() },
        connect: { try await GoogleAccountSession.shared.connect($0) },
        disconnect: { try await GoogleAccountSession.shared.disconnect() },
        call: { name, arguments in
            @Shared(.googleConnection) var connection
            guard let tool = GoogleTool(rawValue: name), connection.isAvailable(tool.service) else { throw GoogleToolError.disconnected }
            let accountID = connection.userID
            var request = try tool.request(arguments: arguments)
            let token = try await GoogleAccountSession.shared.token(for: connection, service: tool.service)
            try Task.checkCancellation()
            guard connection.userID == accountID, connection.isAvailable(tool.service) else { throw GoogleToolError.disconnected }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 45
            let session = URLSession(configuration: configuration, delegate: GoogleRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleToolError.unreadable }
            guard (200..<300).contains(http.statusCode) else {
                switch http.statusCode {
                case 401: throw GoogleToolError.message("Google sign-in expired. Reconnect this service in Plugins.")
                case 403: throw GoogleToolError.message("Google denied access. Check the connection permissions and that this Google API is enabled for Hestrel.")
                case 404: throw GoogleToolError.message("This Google item was not found or is not shared with your account.")
                case 429: throw GoogleToolError.message("Google is rate limiting requests. Try again shortly.")
                default: throw GoogleToolError.message("Google returned HTTP \(http.statusCode). Try again later.")
                }
            }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 2_000_000 { throw GoogleToolError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard connection.userID == accountID, connection.isAvailable(tool.service) else { throw GoogleToolError.disconnected }
            return ToolResult(content: try tool.result(data: data), isError: false)
        }
    )
    static let testValue = GoogleClient()
}

/// SDK handles OAuth state/PKCE, Keychain persistence and token renewal. Never send Google tokens to a model.
@MainActor
private final class GoogleAccountSession {
    static let shared = GoogleAccountSession()

    func configure() throws {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("$(") else {
            throw GoogleToolError.message("Google connections aren’t configured in this build yet.")
        }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard schemes.contains(reversed) else { throw GoogleToolError.message("Google sign-in callback is missing from this build.") }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    }

    func restore() async throws -> GoogleConnection? {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return nil }
        try configure()
        let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
        return snapshot(user)
    }

    func connect(_ service: GoogleService) async throws -> GoogleConnection {
        try configure()
        let signIn = GIDSignIn.sharedInstance
        do {
            if signIn.currentUser == nil, signIn.hasPreviousSignIn() {
                _ = try await signIn.restorePreviousSignIn()
            }
            if let current = signIn.currentUser { _ = try await current.refreshTokensIfNeeded() }
        } catch {
            let nsError = error as NSError
            guard nsError.domain == "com.google.GIDSignIn", [-4, -11].contains(nsError.code) else { throw error }
            signIn.signOut()
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw GoogleToolError.message("Unable to open Google sign-in. Try again.")
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        let user: GIDGoogleUser
        if let current = signIn.currentUser {
            if current.grantedScopes?.contains(service.scope) == true { user = current }
            else { user = try await current.addScopes([service.scope], presenting: presenter).user }
        } else {
            user = try await signIn.signIn(withPresenting: presenter, hint: nil, additionalScopes: [service.scope]).user
        }
        guard user.grantedScopes?.contains(service.scope) == true else {
            throw GoogleToolError.message("Permission for \(service.title) wasn’t granted. Connect again and allow access to use it.")
        }
        return snapshot(user)
    }

    func disconnect() async throws {
        try await GIDSignIn.sharedInstance.disconnect()
    }

    func token(for connection: GoogleConnection, service: GoogleService) async throws -> String {
        try configure()
        let signIn = GIDSignIn.sharedInstance
        if signIn.currentUser == nil { _ = try await signIn.restorePreviousSignIn() }
        guard let current = signIn.currentUser, current.userID == connection.userID else { throw GoogleToolError.disconnected }
        let refreshed = try await current.refreshTokensIfNeeded()
        guard refreshed.userID == connection.userID, refreshed.grantedScopes?.contains(service.scope) == true else { throw GoogleToolError.disconnected }
        return refreshed.accessToken.tokenString
    }

    private func snapshot(_ user: GIDGoogleUser) -> GoogleConnection {
        GoogleConnection(userID: user.userID, email: user.profile?.email, grantedScopes: Set(user.grantedScopes ?? []))
    }
}

/// Fixed Google API requests must not redirect the access token to another endpoint.
nonisolated private final class GoogleRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
