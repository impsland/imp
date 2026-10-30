import Foundation
import ImpKit
import Security

/// Generic passwords in the Keychain: usable in the background after the first unlock, never copied
/// to another device.
private enum Keychain {
    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ service: String, _ account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data, _ service: String, _ account: String) {
        delete(service, account)
        var q = query(service, account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ service: String, _ account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// The pairing holds the secret that opens the link, so it lives in the Keychain, not in preferences.
enum PairingStore {
    private static let service = "app.imp.ImpPhone.pairing"
    private static let account = "mac"

    static func load() -> LinkPairing? {
        Keychain.read(service, account).flatMap { try? JSONDecoder().decode(LinkPairing.self, from: $0) }
    }

    static func save(_ pairing: LinkPairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        Keychain.write(data, service, account)
    }

    static func delete() { Keychain.delete(service, account) }
}

/// The keys and header values of the Imps hatched on this iPhone. Nothing else holds them.
struct PocketKeychain: PocketSecrets {
    private static let service = "app.imp.ImpPhone.pocket"

    func get(_ slot: PocketSlot, imp: UUID) -> String? {
        Keychain.read(Self.service, slot.account(imp: imp)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ value: String, _ slot: PocketSlot, imp: UUID) {
        Keychain.write(Data(value.utf8), Self.service, slot.account(imp: imp))
    }

    func remove(_ slot: PocketSlot, imp: UUID) {
        Keychain.delete(Self.service, slot.account(imp: imp))
    }
}
