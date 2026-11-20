import Foundation

/// Everything Imp keeps on this Mac, and wiping it: what's left is a Mac where Imp never ran.
///
/// - The app's own preferences (appearance, the bubble, where each Imp stands) and window frames, all in
///   Imp's `UserDefaults` domain.
/// - Imp's folder in Application Support: each Imp's own folder (its tools and pictures), saved chats and
///   memories, the browser extension's copy.
/// - What macOS caches for the app (URL caches, saved window state).
/// - Only when asked (`erase(includingSharedConfiguration:)`): the shared configuration, which `imp` uses too:
///   `imp.json` and `auth.json` (every service, key, tool server and trigger) and the Imps' agent files.
public struct FactoryReset {
    public var defaults: UserDefaults
    public var domain: String
    public var folders: [URL]
    /// The files of the shared configuration (see `SharedConfigStore.files`).
    public var sharedFiles: [URL]

    public init(defaults: UserDefaults, domain: String, folders: [URL], sharedFiles: [URL] = []) {
        self.defaults = defaults
        self.domain = domain
        self.folders = folders
        self.sharedFiles = sharedFiles
    }

    /// The real thing, for the running app.
    public static func app(bundleID: String = Bundle.main.bundleIdentifier ?? "app.imp.Imp", shared: SharedConfigStore? = nil) -> FactoryReset {
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
            sharedFiles: shared?.files() ?? [])
    }

    /// Wipes the app's own data. Returns what couldn't be removed (empty when everything went). The shared
    /// configuration is kept, since `imp` uses it, unless `includingSharedConfiguration`.
    @discardableResult
    public func erase(includingSharedConfiguration: Bool = false) -> [String] {
        var left: [String] = []
        ChatHistory.flush()                             // nothing half-written lands after the wipe
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        let fm = FileManager.default
        let doomed = folders + (includingSharedConfiguration ? sharedFiles : [])
        for item in doomed where fm.fileExists(atPath: item.path) {
            do { try fm.removeItem(at: item) } catch { left.append(item.path) }
        }
        return left
    }
}
