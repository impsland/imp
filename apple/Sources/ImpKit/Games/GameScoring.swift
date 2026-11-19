import Foundation

/// What a bonk (two Imps meeting while one is flying) is worth in Embers, and when.
///
/// The intent of the game is that the player scores by flinging Imps through embers; a bonk is a
/// small reward for a trick shot, not a way to farm. Pairs of Imps grow with the square of their
/// number (100 Imps are 4,950 pairs), so paying every pair would make the score a function of the
/// crowd rather than of the player. The rule: **a bonk pays at most once per `interval` seconds of
/// play, however many Imps there are** (the bounce still happens, it just stops paying). A round of
/// `length` seconds can therefore earn at most `length / interval` bonks, the same for 2 Imps or 100.
/// Caught embers still grow with the Imps (more Imps reach more embers), which is why the best is
/// kept per number of Imps (see `GameBests`).
public struct BonkPayout: Equatable, Sendable {
    /// The shortest time between two paying bonks.
    public static let interval = 1.0
    /// What a paying bonk earns; doubled in the Blaze.
    public static let points = 3

    private var quiet = 0.0

    public init() {}

    /// Time passes.
    public mutating func advance(_ dt: Double) {
        quiet = max(0, quiet - dt)
    }

    /// A bonk happened: what it earns now (0 while an earlier one is still being paid).
    public mutating func pay(blaze: Bool) -> Int {
        guard quiet <= 0 else { return 0 }
        quiet = Self.interval
        return blaze ? Self.points * 2 : Self.points
    }
}

/// The best score of a game for each number of Imps that played it. A score is only ever compared
/// with games played by the same number of Imps, so a round with 8 Imps never has to beat one with 2.
public struct GameBests: Equatable, Sendable {
    /// Best score by number of Imps.
    public private(set) var scores: [Int: Int]

    public init(_ scores: [Int: Int] = [:]) {
        self.scores = scores
    }

    /// The best for games with this many Imps (0 if none was played).
    public func best(imps: Int) -> Int { scores[imps] ?? 0 }

    /// Keeps the score if it beats the best for the same number of Imps. A first game with a score
    /// above 0 is a record; a score of 0 never is.
    @discardableResult
    public mutating func record(score: Int, imps: Int) -> Bool {
        guard score > best(imps: imps) else { return false }
        scores[imps] = score
        return true
    }

    // MARK: Storage

    /// Reads the bests kept under `key` (a dictionary of Imp count to score).
    public init(defaults: UserDefaults, key: String) {
        let stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        self.init(Dictionary(uniqueKeysWithValues: stored.compactMap { count, score in Int(count).map { ($0, score) } }))
    }

    public func save(to defaults: UserDefaults, key: String) {
        defaults.set(Dictionary(uniqueKeysWithValues: scores.map { (String($0.key), $0.value) }), forKey: key)
    }
}
