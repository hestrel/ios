import ComposableArchitecture
import Foundation
import Security

/// Stores secrets (provider API keys, MCP server tokens) in the Keychain, keyed by the owner's ID.
@DependencyClient
nonisolated struct CredentialsClient: Sendable {
    var secret: @Sendable (_ id: UUID) -> String? = { _ in nil }
    var setSecret: @Sendable (_ value: String?, _ id: UUID) -> Void
}

nonisolated extension CredentialsClient: DependencyKey {
    static let liveValue: CredentialsClient = {
        let service = "\(Bundle.main.bundleIdentifier ?? "hestrel").api-keys"

        @Sendable func query(for id: UUID) -> [CFString: Any] {
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: id.uuidString,
            ]
        }

        return CredentialsClient(
            secret: { id in
                var query = query(for: id)
                query[kSecReturnData] = true
                query[kSecMatchLimit] = kSecMatchLimitOne
                var result: AnyObject?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let data = result as? Data
                else { return nil }
                return String(decoding: data, as: UTF8.self)
            },
            setSecret: { value, id in
                let query = query(for: id)
                guard let value = value?.nonBlank else {
                    SecItemDelete(query as CFDictionary)
                    return
                }
                let data = Data(value.utf8)
                let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
                guard status == errSecItemNotFound else { return }
                var item = query
                item[kSecValueData] = data
                item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(item as CFDictionary, nil)
            }
        )
    }()

    static var previewValue: CredentialsClient {
        let storage = LockIsolated<[UUID: String]>([:])
        return CredentialsClient(
            secret: { storage.value[$0] },
            setSecret: { value, id in storage.withValue { $0[id] = value } }
        )
    }

    static let testValue = CredentialsClient()
}

nonisolated extension DependencyValues {
    var credentials: CredentialsClient {
        get { self[CredentialsClient.self] }
        set { self[CredentialsClient.self] = newValue }
    }
}
