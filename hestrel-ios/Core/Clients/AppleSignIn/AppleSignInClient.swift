import AuthenticationServices
import ComposableArchitecture
import CryptoKit
import Foundation

/// What a successful Sign in with Apple hands the app.
nonisolated struct AppleCredential: Equatable, Sendable {
    let identityToken: String
    let authorizationCode: String?
    /// The raw nonce whose SHA-256 was put in the request; the server checks it against the token.
    let nonce: String

    init?(authorization: ASAuthorization, nonce: String) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8)
        else { return nil }
        self.identityToken = identityToken
        self.authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        self.nonce = nonce
    }

    static func makeNonce() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
    }

    static func hashed(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum AppleSignInError: LocalizedError {
    case missingCredential

    var errorDescription: String? { "Sign in with Apple didn’t return a usable credential." }
}

/// Runs Sign in with Apple outside of `SignInWithAppleButton`, e.g. to re-authenticate before
/// deleting the account, which needs a fresh authorization code.
@DependencyClient
nonisolated struct AppleSignInClient: Sendable {
    var authorize: @Sendable () async throws -> AppleCredential
}

nonisolated extension AppleSignInClient: DependencyKey {
    static let liveValue = AppleSignInClient(
        authorize: {
            let nonce = AppleCredential.makeNonce()
            let authorization = try await AppleAuthorizationRunner.run(hashedNonce: AppleCredential.hashed(nonce))
            guard let credential = AppleCredential(authorization: authorization, nonce: nonce) else {
                throw AppleSignInError.missingCredential
            }
            return credential
        }
    )

    static let testValue = AppleSignInClient()
}

nonisolated extension DependencyValues {
    var appleSignIn: AppleSignInClient {
        get { self[AppleSignInClient.self] }
        set { self[AppleSignInClient.self] = newValue }
    }
}

/// Bridges `ASAuthorizationController`'s delegate callbacks to async/await.
@MainActor
private final class AppleAuthorizationRunner: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private var continuation: CheckedContinuation<ASAuthorization, any Error>?
    private static var inFlight: AppleAuthorizationRunner?

    static func run(hashedNonce: String) async throws -> ASAuthorization {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = hashedNonce

        let runner = AppleAuthorizationRunner()
        inFlight = runner
        defer { inFlight = nil }
        return try await withCheckedThrowingContinuation { continuation in
            runner.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = runner
            controller.presentationContextProvider = runner
            controller.performRequests()
        }
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return window }
        return ASPresentationAnchor(windowScene: scenes[0])
    }
}
