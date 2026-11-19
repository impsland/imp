import Foundation

/// Listening in more than one language without asking which one first.
///
/// With Automatic on, the microphone feeds one recognizer for each candidate language at the same
/// time, so nothing waits for a guess and no audio is replayed. The bubble shows the live words of
/// the language heard last time (the sticky one). When the person stops, every recognizer's final
/// words are scored and the best one wins. The sticky language wins ties, so a short "yes" or a
/// name never flips the language.
///
/// Everything stays on the device: no model to download and nothing sent anywhere that a single
/// language would not send.
public enum ListeningLanguages {
    /// The value of `ImpPreferences.dictationLocale` that turns Automatic on.
    public static let automatic = "auto"
    /// How many languages listen at once. Each one is a recognizer running on the same audio.
    public static let maxLanguages = 3
    /// How far another language must score above the sticky one to take over.
    public static let switchMargin = 0.08

    /// The locales to listen in, the sticky one first. `chosen` are the person's picks; when there are
    /// none, the device's preferred languages are used. Each is matched to a locale the recognizer
    /// supports: the same identifier, else the same language (in `region` when there is one).
    public static func candidates(chosen: [String], preferred: [String], supported: [String],
                                  region: String?, sticky: String?) -> [String] {
        let wanted = chosen.isEmpty ? preferred : chosen
        var out: [String] = []
        for id in wanted {
            guard let match = match(id, in: supported, region: region) else { continue }
            // From the device's languages, one locale per language (English (US) and English (UK) are one choice).
            if chosen.isEmpty, out.contains(where: { language(of: $0) == language(of: match) }) { continue }
            if !out.contains(match) { out.append(match) }
            if out.count == maxLanguages { break }
        }
        if let sticky, let i = out.firstIndex(of: sticky) { out.insert(out.remove(at: i), at: 0) }
        return out
    }

    /// The supported locale for an identifier, or nil.
    static func match(_ id: String, in supported: [String], region: String?) -> String? {
        let id = normalized(id)
        if let exact = supported.first(where: { normalized($0) == id }) { return exact }
        let lang = language(of: id)
        let same = supported.filter { language(of: $0) == lang }.sorted()
        if let region, let local = same.first(where: { normalized($0).hasSuffix("-" + region.lowercased()) }) { return local }
        return same.first
    }

    static func normalized(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-").lowercased() }

    static func language(of id: String) -> String {
        String(normalized(id).split(separator: "-").first ?? "")
    }

    /// What one language's recognizer heard.
    public struct Heard: Equatable, Sendable {
        public var locale: String
        public var text: String
        /// The recognizer's mean confidence over the words, 0…1. 0 when it gave none.
        public var confidence: Double
        /// How much the words read as that language, 0…1 (a text language check).
        public var fit: Double

        public init(locale: String, text: String, confidence: Double, fit: Double) {
            self.locale = locale; self.text = text; self.confidence = confidence; self.fit = fit
        }

        /// A recognizer in the wrong language still writes words, but with low confidence, and in
        /// words that don't read as its language. Without a confidence, the text check decides alone.
        public var score: Double { confidence > 0 ? 0.6 * confidence + 0.4 * fit : fit }
    }

    /// The best of what was heard. The sticky language keeps the turn unless another scores
    /// clearly higher (`switchMargin`). Nil when nobody heard words.
    public static func pick(_ heard: [Heard], sticky: String?) -> Heard? {
        let spoken = heard.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let best = spoken.max(by: { $0.score < $1.score }) else { return nil }
        if let sticky, let own = spoken.first(where: { $0.locale == sticky }), best.score - own.score < switchMargin {
            return own
        }
        return best
    }
}
