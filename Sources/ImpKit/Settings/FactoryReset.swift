import Foundation
import Security

/// Everything Imp keeps on this Mac, and wiping it: what's left is a Mac where Imp never ran.
///
/// - the preferences (every Imp, service, borrowed tool, trigger and setting) and window frames,
///   all in Imp's `UserDefaults` domain;
/// - Imp's folder in Application Support: the key file, each Imp's own folder (its tools and
///   pictures), saved chats and memories, the browser extension's copy;
/// - API keys kept in the Keychain;
/// - what macOS caches for the app (URL caches, saved window state).
public struct FactoryReset {
    public var defaults: UserDefaults
    public var domain: String
    public var folders: [URL]
    public var keychainService: String?

    public init(defaults: UserDefaults, domain: String, folders: [URL], keychainService: String?) {
        self.defaults = defaults
        self.domain = domain
        self.folders = folders
        self.keychainService = keychainService
    }

    /// The real thing, for the running app.
    public static func app(bundleID: String = Bundle.main.bundleIdentifier ?? Keychain.service) -> FactoryReset {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return FactoryReset(
            defaults: .standard, domain: bundleID,
            folders: [
                URL.applicationSupportDirectory.appendingPathComponent("Imp", isDirectory: true),
                library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true),
                library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true),
                library.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true),
            ],
            keychainService: Keychain.service)
    }

    /// Wipes it all. Returns what couldn't be removed (empty when everything went).
    @discardableResult
    public func erase() -> [String] {
        var left: [String] = []
        ChatHistory.flush()                             // nothing half-written lands after the wipe
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        let fm = FileManager.default
        for folder in folders where fm.fileExists(atPath: folder.path) {
            do { try fm.removeItem(at: folder) } catch { left.append(folder.path) }
        }
        if let keychainService, !Self.eraseKeychain(service: keychainService) { left.append("Keychain items for \(keychainService)") }
        return left
    }

    /// Deletes every generic password saved under `service`. Never reads a secret, so never asks
    /// for the password.
    static func eraseKeychain(service: String) -> Bool {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        // macOS deletes every match at once, but older keychains may take a few goes.
        for _ in 0..<64 {
            switch SecItemDelete(query as CFDictionary) {
            case errSecSuccess: continue
            case errSecItemNotFound: return true
            default: return false
            }
        }
        return false
    }
}
