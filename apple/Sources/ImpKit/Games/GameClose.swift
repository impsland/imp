/// What the close (X) of a game does, the same rule for Embers and Echo and on every platform.
///
/// Once a round is being scored, closing it ends it now and shows the results card with what was
/// scored so far (never a silent exit, so a good score is not thrown away). Before that (the guided
/// step, the rules and the countdown) nothing has been scored, so closing leaves the game directly:
/// there is no result to show and no record to claim.
public enum GameClose: Equatable, Sendable {
    /// End the round now and show the results card.
    case results
    /// Leave the game without a results card.
    case leave

    public static func when(scoring: Bool) -> GameClose { scoring ? .results : .leave }
}

extension EchoRound {
    /// The round is being scored: past the guided step, the rules and the countdown, and not over.
    public var isScoring: Bool {
        !isLesson && (phase == .watching || phase == .repeating || phase == .between)
    }

    /// What closing the game does right now.
    public var closing: GameClose { .when(scoring: isScoring) }
}
