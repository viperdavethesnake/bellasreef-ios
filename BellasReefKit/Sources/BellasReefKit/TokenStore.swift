// Bella's Reef iOS — closed source.

import Foundation
import Security

/// Keychain storage for the refresh token.
///
/// Only the **refresh** token is persisted. Access tokens live ~15 minutes and
/// are held in memory: writing them to the Keychain would mean storing a
/// short-lived secret in durable storage for no benefit, and it would survive
/// a revocation that was supposed to end the session.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
/// * *AfterFirstUnlock* so a background reconnect works with the phone locked —
///   which is the normal case for a tank monitor.
/// * *ThisDeviceOnly* so the token never rides an iCloud backup onto another
///   device. A paired credential is bound to the phone the operator approved.
public struct TokenStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "com.bellasreef.app", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    public enum StoreError: Error, CustomStringConvertible {
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case let .keychain(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ token: String, hub: String) throws {
        guard let data = token.data(using: .utf8) else { return }

        var query = baseQuery
        query[kSecAttrLabel as String] = hub

        // Delete-then-add rather than update: SecItemUpdate cannot change
        // accessibility, and a stale attribute is the kind of thing that only
        // shows up as "why won't it reconnect while locked".
        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Forget the credential. Called on revocation and on explicit unpair.
    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
