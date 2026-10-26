import Foundation
import Security

/// Stores the API keys in the login keychain (never in UserDefaults).
///
/// macOS asks for the user's password when an app reads a secret it isn't trusted with yet (an
/// item saved by another build, say). Only `read` touches the secret; `contains` checks that an
/// item is there without it, and so never asks.
public enum Keychain {
    public static let service = "app.imp.Imp"

    /// macOS didn't hand the key over: the user chose Deny or cancelled the password prompt.
    public struct AccessDenied: Error, Equatable {
        public let status: OSStatus
    }

    /// Whether a key is saved for `account`, without reading it.
    public static func contains(_ account: String) -> Bool {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// The saved key (nil when there is none). May ask for the user's password, so call it only
    /// for something they asked for. Throws `AccessDenied` when they refuse.
    public static func read(_ account: String) throws -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound: return nil
        default: throw AccessDenied(status: status)
        }
    }

    @discardableResult
    public static func write(_ value: String, account: String) -> Bool {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if value.isEmpty { return SecItemDelete(base as CFDictionary) == errSecSuccess }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}
