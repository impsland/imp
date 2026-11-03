import CoreGraphics
import Foundation

/// How an Imp follows the cursor.
public enum FollowMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Not at all: it looks straight ahead and stays put.
    case off
    /// Only its eyes and head turn toward the cursor.
    case eyes
    /// It hops after the cursor, a few hops at a time.
    case hop
    /// It slides after the cursor.
    case glide

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .eyes: String(localized: "Eyes")
        case .hop: String(localized: "Hop")
        case .glide: String(localized: "Glide")
        }
    }

    public var symbol: String {
        switch self {
        case .off: "eye.slash"
        case .eyes: "eye"
        case .hop: "figure.jumprope"
        case .glide: "wind"
        }
    }

    /// The mode that is in effect: with Reduce Motion on, hops and glides become eyes.
    public func effective(reduceMotion: Bool) -> FollowMode {
        reduceMotion && movesBody ? .eyes : self
    }

    /// The body travels across the screen.
    public var movesBody: Bool { self == .hop || self == .glide }

    /// Its eyes turn toward the cursor.
    public var eyesFollow: Bool { self != .off }
}

/// One hop toward the cursor: where it starts and lands (the Imp's centre), how long it takes,
/// how high it goes, and how long it rests before the next.
public struct HopLeg: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
    public var duration: Double
    public var height: Double
    public var pause: Double

    /// Where the Imp's centre is `k` of the way through (0 to 1): along the ground, lifted by an arc.
    public func center(at k: Double) -> CGPoint {
        let t = min(max(k, 0), 1)
        let ground = self.ground(at: t)
        return CGPoint(x: ground.x, y: ground.y + height * 4 * t * (1 - t))
    }

    /// The same point without the lift: where the Imp stands if a hop is cut short.
    public func ground(at k: Double) -> CGPoint {
        let t = min(max(k, 0), 1)
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }
}

/// The arithmetic of following the cursor across the screen. Positions are the Imp's centre in
/// screen points, `side` is the size of its square window.
public enum FollowMath {
    public static let speedRange = 0.5...2.0
    public static let defaultSpeed = 1.0

    public static func clampedSpeed(_ speed: Double) -> Double { min(max(speed, speedRange.lowerBound), speedRange.upperBound) }

    /// How near the Imp's centre comes to the cursor: close enough to keep company, far enough to leave the cursor free.
    public static func stopDistance(side: Double) -> Double { side * 0.9 }

    /// Points per second a glide covers at speed 1.
    static let glideRate = 280.0
    /// A glide slows down over this many sides before it stops.
    static let easeSides = 1.5
    /// Within this much of the stopping distance it counts as arrived.
    static let slack = 6.0

    /// Where the Imp's centre should be: `stopDistance` short of the cursor, on the line from the Imp to it.
    /// Nil when it is already there (or nearer), so there is nothing to do.
    public static func target(center: CGPoint, cursor: CGPoint, side: Double) -> CGPoint? {
        let dx = cursor.x - center.x, dy = cursor.y - center.y
        let d = hypot(dx, dy), stop = stopDistance(side: side)
        guard d > stop + slack else { return nil }
        let k = (d - stop) / d
        return CGPoint(x: center.x + dx * k, y: center.y + dy * k)
    }

    /// One frame of a glide: `dt` seconds toward `target`, quicker when far, easing in the last
    /// stretch, and never past it.
    public static func glideStep(center: CGPoint, toward target: CGPoint, side: Double, speed: Double, dt: Double) -> CGPoint {
        let dx = target.x - center.x, dy = target.y - center.y
        let d = hypot(dx, dy)
        guard d > 0.01, dt > 0 else { return target }
        let ease = min(1, max(d / (side * easeSides), 0.15))
        let travel = min(d, glideRate * clampedSpeed(speed) * ease * dt)
        return CGPoint(x: center.x + dx / d * travel, y: center.y + dy / d * travel)
    }

    /// The next hop toward the cursor, or nil when the Imp is close enough. A hop covers about a body
    /// and a bit, so a far cursor takes several. A faster speed makes hops quicker and rests shorter.
    public static func hopLeg(center: CGPoint, cursor: CGPoint, side: Double, speed: Double) -> HopLeg? {
        guard let target = target(center: center, cursor: cursor, side: side) else { return nil }
        let dx = target.x - center.x, dy = target.y - center.y
        let d = hypot(dx, dy)
        let length = min(d, side * 1.3)
        let to = CGPoint(x: center.x + dx / d * length, y: center.y + dy / d * length)
        let s = clampedSpeed(speed)
        return HopLeg(from: center, to: to, duration: 0.4 / s, height: side * 0.3 * min(1, length / (side * 0.6)), pause: 0.2 / s)
    }

    /// `center` moved, if needed, so the whole window stays inside `visible` (the screen minus the menu bar and Dock).
    public static func keepVisible(_ center: CGPoint, side: Double, in visible: CGRect) -> CGPoint {
        let half = side / 2
        func fit(_ v: Double, _ lo: Double, _ hi: Double) -> Double { hi < lo ? (lo + hi) / 2 : min(max(v, lo), hi) }
        return CGPoint(x: fit(center.x, visible.minX + half, visible.maxX - half),
                       y: fit(center.y, visible.minY + half, visible.maxY - half))
    }

    /// Whether the Imp should be moving its body at all.
    public static func moves(_ mode: FollowMode, reduceMotion: Bool) -> Bool {
        mode.effective(reduceMotion: reduceMotion).movesBody
    }
}
