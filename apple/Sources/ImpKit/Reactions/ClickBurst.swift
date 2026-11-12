import Foundation

/// Groups clicks on an Imp into a single click, a double-click or a flurry of pokes.
///
/// Each burst does exactly one thing. A single or double click is only decided once the burst
/// is over (no further click within `interval`, at most 0.3 s), so clicking
/// twice opens settings without a bubble popping up first, and poking never does either. The
/// cost is that a plain click waits out that interval; that's the standard trade when a click
/// and a double-click do different things. The flurry fires on the `flurry`-th quick click,
/// right as it lands, so the Imp reacts to being poked without delay.
public struct ClickBurst: Sendable {
    public enum Outcome: Equatable, Sendable {
        case single, double, flurry
    }

    /// Quick clicks that make a flurry.
    public static let flurry = 4

    /// The most a click waits for another. The system double-click interval (half a second by
    /// default) makes every plain click feel slow; quick double-clicks land well within this.
    public static let longestGap: TimeInterval = 0.3

    /// The gap to use: the system's double-click interval, but never longer than `longestGap`.
    public static func gap(system: TimeInterval) -> TimeInterval { min(system, longestGap) }

    /// Longest gap between clicks of one burst (see `gap(system:)`).
    public let interval: TimeInterval
    public private(set) var count = 0
    private var last = -Double.infinity

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// A click at `t` (seconds). Returns what to do right now: only a flurry can't wait.
    public mutating func click(at t: TimeInterval) -> Outcome? {
        if t - last > interval { count = 0 }
        count += 1
        last = t
        return count == Self.flurry ? .flurry : nil
    }

    /// Call `interval` after the last click: how many clicks the finished burst had (nil while it
    /// may still go on, or for a flurry, which already played).
    public mutating func finish(at t: TimeInterval) -> Int? {
        guard count > 0, t - last >= interval - 0.001 else { return nil }
        defer { count = 0 }
        return count >= Self.flurry ? nil : count
    }

    /// Call `interval` after the last click: what the finished burst was (one click, two, or
    /// nothing: three clicks, or a flurry that already played). Nil while it may still go on.
    public mutating func settle(at t: TimeInterval) -> Outcome? {
        guard count > 0, t - last >= interval - 0.001 else { return nil }
        defer { count = 0 }
        switch count {
        case 1: return .single
        case 2: return .double
        default: return nil
        }
    }
}
