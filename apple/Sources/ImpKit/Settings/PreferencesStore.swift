import Foundation

/// Where the app's own preferences live: `LocalPreferences` as one JSON blob in `UserDefaults`. Everything
/// the terminal app shares (Imps, services, tool servers, triggers…) is in the configuration instead
/// (`SharedConfigStore`) and API keys in its `auth.json`. Nothing saved, or data that doesn't decode, is a fresh install.
public struct PreferencesStore {
    public static let key = "preferences.local"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> LocalPreferences {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(LocalPreferences.self, from: $0) } ?? LocalPreferences()
    }

    public func save(_ local: LocalPreferences) {
        guard let data = try? JSONEncoder().encode(local) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
