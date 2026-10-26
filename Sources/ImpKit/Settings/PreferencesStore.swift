import Foundation

/// Where the preferences live: one JSON blob in `UserDefaults`. API keys never go here (they're
/// in the Keychain). Data that doesn't decode (an older format) is a fresh start.
public struct PreferencesStore {
    public static let key = "preferences"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ImpPreferences {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ImpPreferences.self, from: $0) } ?? ImpPreferences()
    }

    public func save(_ preferences: ImpPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
