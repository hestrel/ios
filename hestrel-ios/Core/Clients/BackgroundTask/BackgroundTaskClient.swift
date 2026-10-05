import ComposableArchitecture
import Foundation
import UIKit

/// Keeps work alive briefly after the app leaves the foreground.
///
/// iOS suspends a backgrounded app within seconds, which drops open connections and kills a reply
/// mid-stream. A background task buys roughly half a minute to finish it.
@DependencyClient
nonisolated struct BackgroundTaskClient: Sendable {
    var begin: @Sendable (_ name: String) async -> UIBackgroundTaskIdentifier = { _ in .invalid }
    var end: @Sendable (_ identifier: UIBackgroundTaskIdentifier) async -> Void
}

nonisolated extension BackgroundTaskClient {
    /// Runs `work` inside a background task, ending it however `work` finishes.
    func run<Value: Sendable>(_ name: String, _ work: @Sendable () async throws -> Value) async throws -> Value {
        let identifier = await begin(name: name)
        do {
            let value = try await work()
            await end(identifier: identifier)
            return value
        } catch {
            await end(identifier: identifier)
            throw error
        }
    }
}

nonisolated extension BackgroundTaskClient: DependencyKey {
    static let liveValue = BackgroundTaskClient(
        begin: { name in await beginTask(named: name) },
        end: { identifier in
            guard identifier != .invalid else { return }
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
        }
    )

    @MainActor
    private static func beginTask(named name: String) -> UIBackgroundTaskIdentifier {
        let identifier = LockIsolated(UIBackgroundTaskIdentifier.invalid)
        // When time runs out, iOS requires the task to end; the reply then fails as interrupted.
        let task = UIApplication.shared.beginBackgroundTask(withName: name) {
            // UIKit calls expiration handlers on the main thread.
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier.value) }
        }
        identifier.setValue(task)
        return task
    }

    static let testValue = BackgroundTaskClient(begin: { _ in .invalid }, end: { _ in })
}

nonisolated extension DependencyValues {
    var backgroundTask: BackgroundTaskClient {
        get { self[BackgroundTaskClient.self] }
        set { self[BackgroundTaskClient.self] = newValue }
    }
}
