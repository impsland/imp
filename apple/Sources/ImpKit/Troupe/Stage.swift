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
/// a nod makes others nod, an error makes them wince.
public enum Contagion {
    public static func response(to event: StageEvent) -> Reaction? {
        switch event {
        case .answered: .smile
        case .failed: .wow
        case .annoyed: .wow
        // Contagious, not copied: a greeting, a gasp, a sulk and a doze catch on, each as itself.
        case .reacted(let r): r
        }
    }

    /// Chance each other Imp joins in, so the troupe doesn't move like a chorus line.
    public static let chance = 0.75
}
