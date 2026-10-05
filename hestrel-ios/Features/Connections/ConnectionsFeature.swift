import ComposableArchitecture
import Foundation

@Reducer
struct ConnectionsFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.googleConnection) var connection: GoogleConnection
        var isBusy = false
        var error: String?
    }

    enum Action {
        case task
        case connect(GoogleService)
        case setEnabled(GoogleService, Bool)
        case disconnect
        case reconnect
        case restored(Result<GoogleConnection?, any Error>)
        case connected(GoogleService, Result<GoogleConnection, any Error>)
        case disconnected(Result<Void, any Error>)
    }

    @Dependency(\.google) var google

    var body: some Reducer<State, Action> {
        Reduce<State, Action> { state, action in
            switch action {
            case .task:
                guard !state.isBusy else { return .none }
                state.isBusy = true
                return .run { [google] send in
                    await send(.restored(Result { try await google.restore() }))
                }
            case let .connect(service):
                guard !state.isBusy else { return .none }
                state.isBusy = true
                state.error = nil
                return .run { [google] send in
                    await send(.connected(service, Result { try await google.connect(service) }))
                }
            case let .setEnabled(service, enabled):
                guard !state.isBusy else { return .none }
                if enabled {
                    guard state.connection.userID != nil, state.connection.grantedScopes.contains(service.scope) else {
                        return .send(.connect(service))
                    }
                    state.$connection.withLock { _ = $0.enabledServices.insert(service) }
                } else {
                    state.$connection.withLock { _ = $0.enabledServices.remove(service) }
                }
                return .none
            case .reconnect:
                guard !state.isBusy,
                      let service = GoogleService.allCases.first(where: { state.connection.grantedScopes.contains($0.scope) }) else { return .none }
                state.isBusy = true
                state.error = nil
                return .run { [google] send in
                    await send(.restored(Result { try await google.connect(service) }))
                }
            case .disconnect:
                guard !state.isBusy else { return .none }
                state.isBusy = true
                state.error = nil
                // Stop exposing and executing tools immediately, even if revocation needs a retry.
                state.$connection.withLock { $0.enabledServices.removeAll() }
                return .run { [google] send in
                    await send(.disconnected(Result { try await google.disconnect() }))
                }
            case let .restored(.success(snapshot)):
                state.isBusy = false
                apply(snapshot, to: &state)
                return .none
            case let .connected(service, .success(snapshot)):
                state.isBusy = false
                apply(snapshot, to: &state)
                state.$connection.withLock { _ = $0.enabledServices.insert(service) }
                return .none
            case .disconnected(.success):
                state.isBusy = false
                state.$connection.withLock { $0 = GoogleConnection() }
                return .none
            case let .restored(.failure(error)), let .connected(_, .failure(error)), let .disconnected(.failure(error)):
                state.isBusy = false
                if !error.isGoogleSignInCancellation {
                    state.error = error.localizedDescription
                }
                return .none
            }
        }
    }

    private func apply(_ snapshot: GoogleConnection?, to state: inout State) {
        let previous = state.connection
        var updated = snapshot ?? GoogleConnection()
        if updated.userID == previous.userID {
            updated.enabledServices = previous.enabledServices.filter { updated.grantedScopes.contains($0.scope) }
        }
        state.$connection.withLock { $0 = updated }
    }
}
