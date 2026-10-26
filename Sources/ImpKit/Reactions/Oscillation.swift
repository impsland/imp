import Foundation

/// Counts back-and-forth swings along one axis (a swish, a stroke, a tickle, a shake).
///
/// A turn only counts once the movement has gone back at least `minSwing`, so a trembling hand
/// or a cursor drifting toward something isn't mistaken for swinging.
public struct Oscillation: Sendable {
    /// How long a turn is remembered.
    public let window: TimeInterval
    private var anchor: Double?
    private var direction = 0.0
    private var extreme = 0.0
    /// When it turned around, oldest first (within `window`).
    public private(set) var turns: [TimeInterval] = []

    public init(window: TimeInterval) {
        self.window = window
    }

    public var count: Int { turns.count }

    /// Seconds between the oldest and newest of the last `n` turns (nil if there aren't `n`).
    public func span(ofLast n: Int) -> TimeInterval? {
        guard n > 0, turns.count >= n else { return nil }
        return turns[turns.count - 1] - turns[turns.count - n]
    }

    /// Feeds a position. Returns whether the movement just turned around.
    @discardableResult
    public mutating func add(_ x: Double, at t: TimeInterval, minSwing: Double) -> Bool {
        turns.removeAll { t - $0 > window }
        guard let anchor else {
            self.anchor = x
            extreme = x
            return false
        }
        if direction == 0 {
            if abs(x - anchor) >= minSwing { direction = x > anchor ? 1 : -1; extreme = x }
            return false
        }
        if (x - extreme) * direction > 0 { extreme = x; return false }   // still going the same way
        guard abs(x - extreme) >= minSwing else { return false }
        turns.append(t)
        direction = -direction
        extreme = x
        return true
    }

    public mutating func reset() { self = Oscillation(window: window) }
}
