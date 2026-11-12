import Foundation

/// The animations Imp carries in the app, the ones it needs with no Den: how it greets, smiles
/// when an answer comes, gasps when something fails, sulks over bad news and dozes off. Which of
/// them are bundled is decided once, in `spec/animations/catalog.json` (`"bundled": true`), and
/// `AnimationCatalog` reads them from there. Every other animation comes from the Den.
///
/// Which trigger starts which one is the user's choice (see `AnimationRule`).
public enum Reaction: String, Codable, CaseIterable, Sendable, Identifiable {
    // The ones the app plays on its own: Imps meeting (greet), an answer (smile), a failure (wow),
    // bad news to the others (sad) and an Imp going to sleep (sleep).
    case greet, smile, wow, sad, sleep

    public var id: String { rawValue }

    /// The catalog entry the beats and the starts come from.
    public var entry: AnimationCatalog.Entry { AnimationCatalog.entry(rawValue) ?? AnimationCatalog.missing(rawValue) }

    /// What it plays.
    public var beats: [AnimationBeat] { entry.beats }

    public var title: String {
        switch self {
        case .greet: String(localized: "Nod hello")
        case .smile: String(localized: "Smile")
        case .wow: String(localized: "Gasp")
        case .sad: String(localized: "Sulk")
        case .sleep: String(localized: "Doze")
        }
    }

    /// What it looks like, in a few words.
    public var summary: String {
        switch self {
        case .greet: String(localized: "A friendly double nod.")
        case .smile: String(localized: "Happy squinty eyes.")
        case .wow: String(localized: "Eyes wide, an exclamation mark.")
        case .sad: String(localized: "Looks down and sulks.")
        case .sleep: String(localized: "Nods off for a moment.")
        }
    }

    public var symbol: String {
        switch self {
        case .greet: "hand.wave.fill"
        case .smile: "face.smiling.inverse"
        case .wow: "exclamationmark.circle.fill"
        case .sad: "cloud.rain.fill"
        case .sleep: "moon.zzz.fill"
        }
    }
}
