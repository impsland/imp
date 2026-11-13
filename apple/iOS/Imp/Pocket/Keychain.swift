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

    /// Deletes every item of `service`. True when none is left (or there was none); false when the
    /// Keychain can't be changed now (before the first unlock).
    static func deleteAll(_ service: String) -> Bool {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// iOS deletes an app's files and preferences with the app, but keeps its Keychain items. Without care a
/// new install would find the old link book (and the keys of Imps that are gone): it would believe a
/// device is linked, bring the network up at launch and so ask for the Local Network permission before
/// anyone asked to link. A new install starts clean instead.
enum InstallRecord {
    private static let key = "installRecorded"

    /// Run once at launch, before anything reads the Keychain. An install that has run before keeps
    /// everything: its preferences or its files show it (an update keeps both). Only a container with no
    /// trace of an earlier run has its leftovers removed.
    static func clearLeftovers(defaults: UserDefaults = .standard, bundle: Bundle = .main,
                               files: URL = .applicationSupportDirectory) {
        guard !defaults.bool(forKey: key) else { return }
        let preferences = bundle.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: files.path(percentEncoded: false))) ?? []
        if preferences.isEmpty && saved.isEmpty {
            // Before the first unlock nothing can be told or removed: the next launch tries again.
            guard Keychain.deleteAll(KeychainLinkStorage.service), Keychain.deleteAll(PocketKeychain.service) else { return }
        }
        defaults.set(true, forKey: key)
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
    static let service = "app.imp.ImpPhone.link"
    private static let account = "book"

    func load() throws -> Data? {
        var q = Keychain.query(Self.service, Self.account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainFailure(status: status) }
        return data
    }

    func erase() throws { Keychain.delete(Self.service, Self.account) }

    func save(_ book: Data) throws {
        let status = Keychain.write(book, Self.service, Self.account)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
}

/// The keys and header values of the Imps hatched on this iPhone. Nothing else holds them.
struct PocketKeychain: PocketSecrets {
    static let service = "app.imp.ImpPhone.pocket"

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
