import Foundation

/// Where the preferences live: one JSON blob in `UserDefaults`. API keys never go here (they're
/// in the Keychain). Nothing saved, or data that doesn't decode (an older format), is a fresh install (bare `ImpPreferences()`).
public struct PreferencesStore {
    public static let key = "preferences"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ImpPreferences {
        var prefs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ImpPreferences.self, from: $0) } ?? ImpPreferences()
        // Triggers saved in an older shape come back without steps: drop them, keep everything else.
        prefs.shortcuts.removeAll { !$0.isValid }
        return prefs
    }

    public func save(_ preferences: ImpPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
