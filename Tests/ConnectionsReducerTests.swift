import ComposableArchitecture
import XCTest
@testable import ConnectionsAdapter

@MainActor
final class ConnectionsReducerTests: XCTestCase {
    func testConnectingOneServiceDoesNotEnableOtherGrantedServices() async {
        let snapshot = GoogleConnection(userID: "user", email: "user@example.com", grantedScopes: Set(GoogleService.allCases.map(\.scope)))
        let store = TestStore(initialState: ConnectionsFeature.State()) { ConnectionsFeature() } withDependencies: {
            $0.google.connect = { _ in snapshot }
        }
        await store.send(.connect(.gmail)) { $0.isBusy = true }
        await store.receive(\.connected) {
            $0.isBusy = false
            $0.$connection.withLock {
                $0 = snapshot
                $0.enabledServices = [.gmail]
            }
        }
    }

    func testDeclinedConsentDoesNotEnableTools() async {
        let store = TestStore(initialState: ConnectionsFeature.State()) { ConnectionsFeature() } withDependencies: {
            $0.google.connect = { _ in throw GoogleToolError.message("Permission declined") }
        }
        await store.send(.connect(.drive)) { $0.isBusy = true }
        await store.receive(\.connected) {
            $0.isBusy = false
            $0.error = "Permission declined"
        }
        XCTAssertTrue(store.state.connection.tools.isEmpty)
    }

    func testDisconnectDisablesBeforeRevocationCompletes() async {
        let state = ConnectionsFeature.State()
        state.$connection.withLock { $0 = GoogleConnection(userID: "user", grantedScopes: [GoogleService.gmail.scope], enabledServices: [.gmail]) }
        let store = TestStore(initialState: state) { ConnectionsFeature() } withDependencies: {
            $0.google.disconnect = { throw GoogleToolError.message("Offline") }
        }
        await store.send(.disconnect) {
            $0.isBusy = true
            $0.$connection.withLock { $0.enabledServices = [] }
        }
        await store.receive(\.disconnected) {
            $0.isBusy = false
            $0.error = "Offline"
        }
        XCTAssertTrue(store.state.connection.tools.isEmpty)
    }

    func testRestoringDifferentAccountClearsPreviousEnabledServices() async {
        let state = ConnectionsFeature.State()
        state.$connection.withLock { $0 = GoogleConnection(userID: "old", grantedScopes: [GoogleService.gmail.scope], enabledServices: [.gmail]) }
        let new = GoogleConnection(userID: "new", grantedScopes: [GoogleService.gmail.scope])
        let store = TestStore(initialState: state) { ConnectionsFeature() } withDependencies: {
            $0.google.restore = { new }
        }
        await store.send(.task) { $0.isBusy = true }
        await store.receive(\.restored) {
            $0.isBusy = false
            $0.$connection.withLock { $0 = new }
        }
        XCTAssertTrue(store.state.connection.tools.isEmpty)
    }
}
