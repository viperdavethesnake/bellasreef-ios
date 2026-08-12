// Bella's Reef iOS — closed source.

import Foundation
import Security

/// Where the refresh token lives.
///
/// A protocol so `HubClient` can be driven by a test without a Keychain, and so
/// the pre-flight below is something a caller can *require* rather than hope
/// for. `TokenStore` is the only production conformance.
public protocol CredentialStore: Sendable {
    /// Prove a write would succeed, without keeping anything.
    ///
    /// Called **before** `POST /pair`, because the failure it catches is
    /// otherwise unrecoverable: the hub issues one credential per TOFU grant or
    /// recovery window, spends the window doing it, and a store failure
    /// afterwards discards the only copy. The operator is then locked out with
    /// SSH as the way back. Probing first moves the failure to the side of the
    /// line where nothing has been spent.
    func probe() throws
    func save(_ token: String, hub: String) throws
    func load() throws -> String?
    func clear() throws
}

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
public struct TokenStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.bellasreef.app", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    public enum StoreError: Error, CustomStringConvertible {
        case keychain(OSStatus)
        /// The write reported success and the read back did not agree. Rare, and
        /// worth its own case: "it saved" and "it is there" are different
        /// claims, and only the second one gets the operator back in.
        case unreadable

        public var description: String {
            switch self {
            case let .keychain(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "keychain error \(status): \(message)"
            case .unreadable:
                return "the keychain accepted a write and could not read it back"
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

    /// Write a canary, read it back, delete it.
    ///
    /// Same class, same accessibility and the same delete-then-add sequence the
    /// real save uses, under a neighbouring account. Anything less would prove
    /// something other than what is about to happen — a probe that tests an
    /// easier operation than the real one is decoration.
    public func probe() throws {
        let canary = UUID().uuidString

        var identity = baseQuery
        identity[kSecAttrAccount as String] = account + ".preflight"

        SecItemDelete(identity as CFDictionary)

        var write = identity
        write[kSecValueData as String] = Data(canary.utf8)
        write[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(write as CFDictionary, nil)
        guard added == errSecSuccess else { throw StoreError.keychain(added) }

        var read = identity
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let found = SecItemCopyMatching(read as CFDictionary, &item)

        // Deleted whatever the read said, so a probe never leaves a row behind.
        SecItemDelete(identity as CFDictionary)

        guard found == errSecSuccess else { throw StoreError.keychain(found) }
        guard let data = item as? Data, String(data: data, encoding: .utf8) == canary else {
            throw StoreError.unreadable
        }
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
