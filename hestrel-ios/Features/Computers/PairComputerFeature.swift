import ComposableArchitecture
import Foundation

/// Pairs a computer running Hestrel's bridge with the account, from the QR code the bridge shows,
/// a `hestrel://pair` link, or the code typed by hand.
@Reducer
struct PairComputerFeature {
    @ObservableState
    struct State: Equatable {
        var typedCode = ""
        var status = Status.scanning
        @Shared(.account) var account: Account?

        enum Status: Equatable {
            case scanning
            case pairing
            case paired(name: String)
            case failed(String)
        }

        init(code: String? = nil) {
            if let code { typedCode = code }
        }

        var canSubmit: Bool {
            PairingLink.code(from: typedCode) != nil && status != .pairing
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case claimFinished(Result<Computer, any Error>)
        case codeScanned(String)
        case delegate(Delegate)
        case doneTapped
        case signInTapped
        case submitTapped
        case task

        enum Delegate: Equatable {
            case paired(Computer)
            case openAccount
        }
    }

    @Dependency(\.credentials) var credentials
    @Dependency(\.dismiss) var dismiss
    @Dependency(\.hestrelAPI) var api

    var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                if case .failed = state.status { state.status = .scanning }
                return .none

            case let .claimFinished(.success(computer)):
                state.status = .paired(name: computer.name)
                return .send(.delegate(.paired(computer)))

            case let .claimFinished(.failure(error)):
                state.status = .failed(error.localizedDescription)
                return .none

            case let .codeScanned(text):
                // The camera keeps reporting the same code; only the first one counts.
                guard state.status == .scanning || isFailure(state.status), let code = PairingLink.code(from: text) else { return .none }
                return claim(code, state: &state)

            case .delegate:
                return .none

            case .doneTapped:
                return .run { [dismiss] _ in await dismiss() }

            case .signInTapped:
                return .send(.delegate(.openAccount))

            case .submitTapped:
                guard let code = PairingLink.code(from: state.typedCode) else { return .none }
                return claim(code, state: &state)

            case .task:
                // Opened from a link: pair right away.
                guard state.account != nil, let code = PairingLink.code(from: state.typedCode) else { return .none }
                return claim(code, state: &state)
            }
        }
    }

    private func claim(_ code: String, state: inout State) -> Effect<Action> {
        guard state.account != nil else { return .none }
        state.status = .pairing
        return .run { [api, credentials] send in
            let result = await Result {
                guard let token = credentials.secret(id: Account.sessionTokenID) else { throw HestrelAPIError.unauthorized }
                return try await api.claimComputer(token: token, code: code)
            }
            await send(.claimFinished(result))
        }
    }

    private func isFailure(_ status: State.Status) -> Bool {
        if case .failed = status { return true }
        return false
    }
}
