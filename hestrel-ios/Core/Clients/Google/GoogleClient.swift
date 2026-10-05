import ComposableArchitecture
import Foundation

@DependencyClient
nonisolated struct GoogleClient: Sendable {
    var restore: @Sendable () async throws -> GoogleConnection?
    var connect: @Sendable (GoogleService) async throws -> GoogleConnection
    var disconnect: @Sendable () async throws -> Void
    var call: @Sendable (_ name: String, _ arguments: String) async throws -> ToolResult
}

nonisolated extension DependencyValues {
    var google: GoogleClient {
        get { self[GoogleClient.self] }
        set { self[GoogleClient.self] = newValue }
    }
}

nonisolated extension Error {
    /// The user dismissed Google sign-in, which isn't worth an error message.
    ///
    /// Matches `GIDSignInError.canceled` without importing the SDK, so features (and their tests) stay SDK-free.
    var isGoogleSignInCancellation: Bool {
        let error = self as NSError
        return error.domain == "com.google.GIDSignIn" && error.code == -5
    }
}
