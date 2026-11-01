import Foundation
import ImpKit
import Security

/// Generic passwords in the Keychain: usable in the background after the first unlock, never copied
/// to another device.
private enum Keychain {
    static func query(_ service: String, _ account: String) -> [String: Any] {
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

    /// Replaces the item in place (the old value stays if that fails), or adds it. The status says whether it was kept.
    @discardableResult
    static func write(_ data: Data, _ service: String, _ account: String) -> OSStatus {
        let access = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemUpdate(query(service, account) as CFDictionary,
                                   [kSecValueData as String: data, kSecAttrAccessible as String: access] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var q = query(service, account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = access
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ service: String, _ account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// What went wrong with the Keychain, as its status code.
struct KeychainFailure: LocalizedError {
    var status: OSStatus
    var errorDescription: String? { SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)" }
}

/// The link book holds this iPhone's signing key and the secrets that open its links, so it lives in
/// the Keychain, not in preferences.
struct KeychainLinkStorage: LinkStorage {
    private static let service = "app.imp.ImpPhone.link"
    private static let account = "book"

    func load() throws -> LinkBook? {
        var q = Keychain.query(Self.service, Self.account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainFailure(status: status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(LinkBook.self, from: data)
    }

    func save(_ book: LinkBook) throws {
        // The same dates as `LinkFileStorage` writes.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let status = Keychain.write(try encoder.encode(book), Self.service, Self.account)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
}

/// The keys and header values of the Imps hatched on this iPhone. Nothing else holds them.
struct PocketKeychain: PocketSecrets {
    private static let service = "app.imp.ImpPhone.pocket"

    func get(_ slot: PocketSlot, imp: UUID) -> String? {
        Keychain.read(Self.service, slot.account(imp: imp)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ value: String, _ slot: PocketSlot, imp: UUID) throws {
        let status = Keychain.write(Data(value.utf8), Self.service, slot.account(imp: imp))
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    func remove(_ slot: PocketSlot, imp: UUID) {
        Keychain.delete(Self.service, slot.account(imp: imp))
    }
}
