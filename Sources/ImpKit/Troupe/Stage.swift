import Foundation

/// Something an Imp just did that the others may notice.
public enum StageEvent: Equatable, Sendable {
    /// Got an answer and is showing it.
    case answered
    /// Something went wrong.
    case failed
    /// Played a reaction (a word you typed, a mouse game…).
    case reacted(Reaction)
    /// Got poked too many times.
    case annoyed
}

/// How the rest of the troupe responds to an Imp's moment. Contagious, not copied:
/// a dizzy friend is funny, a hop makes others hop, an error makes them wince.
public enum Contagion {
    public static func response(to event: StageEvent) -> Reaction? {
        switch event {
        case .answered: .smile
        case .failed: .wow
        case .annoyed: .wow
        case .reacted(let r):
            switch r {
            case .dizzy: .laugh
            case .mean: .wow
            case .jump, .laugh, .greet, .bye, .sad, .wow, .sleep: r
            case .smile, .love, .thanks, .pet, .delight: .smile
            case .angry: .wow
            // Someone yelled "Boo!": the others jump out of their skin.
            case .boo: .flinch
            case .proud, .wheee: .wow
            case .blowKiss: .shy
            case .giggle, .woozy, .pounce: .laugh
            case .missedYou: .greet
            case .flinch, .shiver: .shiver
            // Private moments with you (a cuddle, a stare) aren't a show for the others.
            case .cuddle, .plop, .curious, .shy: nil
            // Routines it plays for itself aren't a moment for the others.
            case .glance, .lookAround, .turn, .hum, .showOff, .wonder, .idea, .nap, .watch,
                 .dance, .yawn, .sneeze, .peekaboo, .stargaze, .bored: nil
            // Its favourite-colour moments are its own.
            case .twirl, .serenade, .cheer, .swoon, .glow: nil
            // Body language belongs to its own answer.
            case .yes, .no, .maybe, .dontKnow, .areYouSure, .notSure, .exactly, .nope, .hmm, .aha,
                 .tada, .sorry, .oops, .impressed, .haha, .loveIt, .sadNews, .careful, .welcome, .confused: nil
            }
        }
    }

    /// Chance each other Imp joins in, so the troupe doesn't move like a chorus line.
    public static let chance = 0.75
}
