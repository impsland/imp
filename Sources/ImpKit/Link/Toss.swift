import CoreGraphics
import Foundation

/// Telling a throw from a carry. An Imp leaves a screen when it's flung hard at one of its *outer*
/// sides: an edge with no other screen beyond it. With several displays side by side, carrying an
/// Imp across from one to the next is just a carry, however fast.
public enum Toss {
    /// Sideways speed (points a second) a throw needs. A brisk carry stays well below it.
    public static let desktopSpeed: CGFloat = 1_400
    /// How close to the edge the pointer must be when the throw is noticed. The pointer stops at
    /// the edge of the screen, so a throw is the moment it hits the edge still going fast.
    public static let desktopZone: CGFloat = 36

    /// A throw off the desktop: the pointer at `cursor`, moving at `velocity` (both in one global
    /// coordinate space, y up as in Cocoa), with the displays' frames. The side it leaves by and
    /// how far down that side (0 top, 1 bottom), or nil.
    public static func desktopExit(cursor: CGPoint, velocity: CGVector, screens: [CGRect]) -> (side: LinkSide, height: Double)? {
        guard abs(velocity.dx) >= desktopSpeed, abs(velocity.dx) >= abs(velocity.dy) * 1.2 else { return nil }
        // The pointer can sit on the very last column (maxX - 1): match it to its screen with a little slack.
        guard let screen = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(cursor) }) else { return nil }
        let side: LinkSide = velocity.dx < 0 ? .left : .right
        let edge = side == .left ? screen.minX : screen.maxX
        guard abs(cursor.x - edge) <= desktopZone else { return nil }
        // Is there another screen just past this edge, at this height? Then it's a carry across.
        let beyond = CGPoint(x: side == .left ? edge - 2 : edge + 2, y: cursor.y)
        guard !screens.contains(where: { $0.contains(beyond) }) else { return nil }
        let height = screen.height > 0 ? Double((screen.maxY - cursor.y) / screen.height) : 0.5
        return (side, min(max(height, 0), 1))
    }

    /// Where an Imp tossed onto the desktop comes in: the screen furthest out on that side (at the
    /// height it was thrown, if a screen reaches that far), and the point on its edge (y up).
    public static func desktopEntry(_ entry: LinkEntry, screens: [CGRect]) -> (screen: CGRect, point: CGPoint)? {
        guard !screens.isEmpty else { return nil }
        let outermost = entry.side == .left ? screens.map(\.minX).min()! : screens.map(\.maxX).max()!
        let candidates = screens.filter { (entry.side == .left ? $0.minX : $0.maxX) == outermost }
        // Prefer the tallest such screen, so the height maps onto a whole display.
        let screen = candidates.max { $0.height < $1.height }!
        let y = screen.maxY - CGFloat(entry.height) * screen.height
        return (screen, CGPoint(x: entry.side == .left ? screen.minX : screen.maxX, y: y))
    }

    /// Flick speed on the phone (points a second).
    public static let phoneSpeed: CGFloat = 900
    /// How close to the side the finger must be when a fast drag counts as a throw while still dragging.
    public static let phoneZone: CGFloat = 28

    /// A throw off the phone's screen while dragging: the finger at `point` in a `bounds`-sized
    /// view (y down), moving at `velocity`.
    public static func phoneExit(point: CGPoint, velocity: CGVector, bounds: CGSize) -> (side: LinkSide, height: Double)? {
        guard abs(velocity.dx) >= phoneSpeed, abs(velocity.dx) >= abs(velocity.dy) * 1.2, bounds.width > 0 else { return nil }
        let side: LinkSide = velocity.dx < 0 ? .left : .right
        let near = side == .left ? point.x <= phoneZone : point.x >= bounds.width - phoneZone
        guard near else { return nil }
        return (side, bounds.height > 0 ? min(max(Double(point.y / bounds.height), 0), 1) : 0.5)
    }

    /// A throw when letting go: where the flick would carry the Imp (`predicted`, as SwiftUI's
    /// drag gesture says) leaves the screen sideways, fast enough.
    public static func phoneRelease(point: CGPoint, predicted: CGPoint, velocity: CGVector, bounds: CGSize) -> (side: LinkSide, height: Double)? {
        guard abs(velocity.dx) >= phoneSpeed, abs(velocity.dx) >= abs(velocity.dy) * 1.2, bounds.width > 0 else { return nil }
        let side: LinkSide = velocity.dx < 0 ? .left : .right
        let out = side == .left ? predicted.x < 0 : predicted.x > bounds.width
        guard out else { return nil }
        return (side, bounds.height > 0 ? min(max(Double(point.y / bounds.height), 0), 1) : 0.5)
    }
}

/// Spots a throw with the whole phone: a sharp sideways jolt. Fed the device's user acceleration
/// along its x axis (g, positive toward the right edge in portrait) many times a second.
///
/// A throw is the first strong push sideways (the hand speeds up toward the target; the stop that
/// follows pushes the other way and is ignored). A shake is several pushes back and forth in a
/// row: that's a shake, not a throw (the Imp gets dizzy instead).
public struct JoltDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case thrown(LinkSide)
        case shaken
    }

    /// Acceleration (g) a push needs to count.
    public var threshold: Double
    /// Pushes this close together belong to one movement.
    public var window: TimeInterval
    /// Pushes back and forth that make a shake.
    public var shakeCount: Int
    /// Quiet time after an event before the next.
    public var cooldown: TimeInterval

    private var pushes: [(t: TimeInterval, sign: Int)] = []
    private var lastSign = 0
    private var quietUntil: TimeInterval = -.infinity
    private var pending: (t: TimeInterval, side: LinkSide)?

    public init(threshold: Double = 2.0, window: TimeInterval = 0.45, shakeCount: Int = 4, cooldown: TimeInterval = 1.0) {
        self.threshold = threshold; self.window = window; self.shakeCount = shakeCount; self.cooldown = cooldown
    }

    /// One sample. Returns a throw once the movement is over (no shake followed), or a shake.
    public mutating func feed(x: Double, at t: TimeInterval) -> Event? {
        guard t >= quietUntil else { return nil }
        pushes.removeAll { t - $0.t > window }
        let sign = abs(x) >= threshold ? (x > 0 ? 1 : -1) : 0
        if sign != 0 && sign != lastSign {
            pushes.append((t, sign))
            if pending == nil, pushes.count == 1 { pending = (t, sign > 0 ? .right : .left) }
            if pushes.count >= shakeCount {
                reset(until: t + cooldown)
                return .shaken
            }
        }
        if sign != 0 || abs(x) < threshold * 0.5 { lastSign = sign }
        // The movement settled without turning into a shake: it was a throw.
        if let p = pending, t - p.t > window, pushes.count < shakeCount {
            reset(until: t + cooldown)
            return .thrown(p.side)
        }
        return nil
    }

    private mutating func reset(until t: TimeInterval) {
        pushes = []
        pending = nil
        lastSign = 0
        quietUntil = t
    }
}
