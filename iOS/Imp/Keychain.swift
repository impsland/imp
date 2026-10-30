import Foundation
import ImpKit
import Security

/// The pairing holds the secret that opens the link, so it lives in the Keychain, not in preferences.
enum PairingStore {
    private static let service = "app.imp.ImpPhone.pairing"
    private static let account = "mac"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> LinkPairing? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(LinkPairing.self, from: data)
    }

    static func save(_ pairing: LinkPairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        // Usable in the background after the first unlock, never copied to another device.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
