import Foundation

/// The language Imp's own text is in: the Mac's, or one picked for Imp alone. Stored exactly as
/// System Settings › General › Language & Region › Applications stores it (`AppleLanguages` in
/// the app's own defaults), so the two always agree. macOS reads it at launch: a change applies
/// once Imp restarts.
public enum AppLanguage {
    /// The languages Imp is translated into (its String Catalogs), English first.
    public static let supported = ["en", "es", "zh-Hans"]
    static let key = "AppleLanguages"

    /// A language's name in that language (English, Español, 简体中文).
    public static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
    }

    /// The language picked for Imp alone, from its own defaults domain (`domain`), or nil to follow
    /// the Mac. A language Imp isn't translated into reads as following the Mac.
    public static func chosen(in domain: [String: Any]?) -> String? {
        guard let first = (domain?[key] as? [String])?.first else { return nil }
        return Bundle.preferredLocalizations(from: supported, forPreferences: [first]).first
            .flatMap { matches($0, first) ? $0 : nil }
    }

    /// Picks a language for Imp alone, or (nil) goes back to following the Mac.
    public static func choose(_ code: String?, in defaults: UserDefaults) {
        if let code, supported.contains(code) { defaults.set([code], forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The language Imp shows with `chosen` picked (nil: the Mac's), given the Mac's own list.
    public static func resolved(chosen: String?, system: [String]) -> String {
        Bundle.preferredLocalizations(from: supported, forPreferences: chosen.map { [$0] } ?? system).first ?? "en"
    }

    /// `preferredLocalizations` falls back to the development language when nothing matches.
    private static func matches(_ localization: String, _ preference: String) -> Bool {
        let a = Locale(identifier: localization).language, b = Locale(identifier: preference).language
        guard a.languageCode == b.languageCode else { return false }
        return a.languageCode != "zh" || a.script == b.script || b.script == nil && b.region?.identifier != "TW" && b.region?.identifier != "HK"
    }
}
