import CoreGraphics
import Foundation

/// Turns two-finger trackpad scrolling into page swipes: the page follows your fingers, and
/// letting go far enough moves to the next page. Vertical scrolls are left alone.
public struct SwipeTracker: Sendable {
    public enum Phase: Sendable { case began, changed, ended, cancelled }

    public enum Output: Equatable, Sendable {
        /// Follow the fingers by this much (points, positive = right).
        case follow(CGFloat)
        /// Go this many pages (+1 = next, −1 = previous).
        case commit(Int)
        /// Not far enough: settle back.
        case cancel
    }

    /// How far to swipe before letting go turns the page.
    public static let threshold: CGFloat = 70
    /// Movement needed to tell a sideways swipe from a vertical scroll.
    static let decideAfter: CGFloat = 6
    /// A notched mouse wheel turns at most one page per this many seconds.
    static let wheelCooldown: TimeInterval = 0.35

    private enum State { case idle, deciding, tracking, ignoring }
    private var state = State.idle
    private var dx: CGFloat = 0, dy: CGFloat = 0
    private var lastWheel = -Double.infinity

    public init() {}

    /// A trackpad scroll event (momentum events shouldn't be fed). Deltas as the system reports
    /// them (they already follow the user's natural-scrolling setting).
    public mutating func scroll(_ phase: Phase, dx deltaX: CGFloat, dy deltaY: CGFloat) -> Output? {
        switch phase {
        case .began:
            state = .deciding
            dx = deltaX; dy = deltaY
            return nil
        case .changed:
            guard state == .deciding || state == .tracking else { return nil }
            dx += deltaX; dy += deltaY
            if state == .deciding {
                guard abs(dx) + abs(dy) >= Self.decideAfter else { return nil }
                state = abs(dx) > abs(dy) * 1.2 ? .tracking : .ignoring
            }
            return state == .tracking ? .follow(dx) : nil
        case .ended, .cancelled:
            defer { state = .idle; dx = 0; dy = 0 }
            guard state == .tracking else { return nil }
            guard phase == .ended, abs(dx) >= Self.threshold else { return .cancel }
            return .commit(dx < 0 ? 1 : -1)              // fingers to the left: the next page comes in
        }
    }

    /// A notched (mouse) wheel turned sideways, e.g. shift-scroll.
    public mutating func wheel(dx deltaX: CGFloat, at time: TimeInterval) -> Output? {
        guard abs(deltaX) >= 1, time - lastWheel >= Self.wheelCooldown else { return nil }
        lastWheel = time
        return .commit(deltaX < 0 ? 1 : -1)
    }
}
