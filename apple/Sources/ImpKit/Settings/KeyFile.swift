import Foundation

/// Where API keys live unless the user asks for the Keychain: one small JSON file in Imp's folder
/// in Application Support that only the user's account can read (permissions 0600), apart from
/// the preferences. Reading it never asks for a password, so a plain "Hello" never shows a
/// system prompt. (The Keychain is opt-in, see `ImpPreferences.keysInKeychain`.)
public struct KeyFile: Sendable {
    public let url: URL

    public init(url: URL = KeyFile.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Imp/keys.json")
    }

    /// Every key, by account.
    public func all() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return keys
    }

    public func read(_ account: String) -> String? { all()[account] }

    /// Saves a key (an empty one removes it). Returns whether it was written.
    @discardableResult
    public func write(_ value: String, account: String) -> Bool {
        var keys = all()
        keys[account] = value.isEmpty ? nil : value
        let fm = FileManager.default
        if keys.isEmpty {
            try? fm.removeItem(at: url)
            return true
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(keys)
            // Created private, so the keys are never readable by others, not even for a moment.
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
