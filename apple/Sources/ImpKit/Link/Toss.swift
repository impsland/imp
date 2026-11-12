import CoreGraphics
import Foundation
import ImpCore

// Telling a throw from a carry, and a throw from a shake. The rules live in `imp-core`. This only
// turns screen geometry into what the core takes and back.

private func point(_ p: CGPoint) -> LinkPoint { LinkPoint(x: p.x, y: p.y) }
private func rect(_ r: CGRect) -> LinkRect { LinkRect(x: r.minX, y: r.minY, width: r.width, height: r.height) }
private func rect(_ r: LinkRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
private func exit(_ e: LinkExit?) -> (side: LinkSide, height: Double)? {
    e.flatMap { e in LinkSide(rawValue: e.side).map { ($0, e.height) } }
}

/// An Imp leaves a screen when it is flung hard at one of its outer sides. Carrying one across from one
/// display to the next is just a carry, however fast.
public enum Toss {
    /// Sideways speed (points a second) a throw off the desktop needs.
    public static var desktopSpeed: CGFloat { CGFloat(linkTossLimits().desktopSpeed) }
    /// How close to the edge the pointer must be when the throw is noticed.
    public static var desktopZone: CGFloat { CGFloat(linkTossLimits().desktopZone) }
    /// Flick speed on the phone (points a second).
    public static var phoneSpeed: CGFloat { CGFloat(linkTossLimits().phoneSpeed) }
    /// How close to the side the finger must be when a fast drag counts as a throw while still dragging.
    public static var phoneZone: CGFloat { CGFloat(linkTossLimits().phoneZone) }

    /// A throw off the desktop: the pointer at `cursor`, moving at `velocity` (one global space, y up as in
    /// Cocoa), with the displays' frames. The side it leaves by and how far down that side, or nil.
    public static func desktopExit(cursor: CGPoint, velocity: CGVector, screens: [CGRect]) -> (side: LinkSide, height: Double)? {
        exit(linkDesktopExit(cursor: point(cursor), dx: velocity.dx, dy: velocity.dy, screens: screens.map(rect)))
    }

    /// The outer side of the desktop a carried Imp is heading for: the pointer at `cursor` is within
    /// `distance` of it. Nil away from every outer side.
    public static func desktopApproach(cursor: CGPoint, within distance: CGFloat, screens: [CGRect])
        -> (side: LinkSide, screen: CGRect, height: Double, gap: CGFloat)? {
        guard let a = linkDesktopApproach(cursor: point(cursor), distance: distance, screens: screens.map(rect)),
              let side = LinkSide(rawValue: a.side) else { return nil }
        return (side, rect(a.screen), a.height, CGFloat(a.gap))
    }

    /// Where an Imp tossed onto the desktop comes in: the screen and the point on its edge (y up).
    public static func desktopEntry(_ entry: LinkEntry, screens: [CGRect]) -> (screen: CGRect, point: CGPoint)? {
        linkDesktopEntry(side: entry.side.rawValue, height: entry.height, screens: screens.map(rect))
            .map { (rect($0.screen), CGPoint(x: $0.point.x, y: $0.point.y)) }
    }

    /// A throw off the phone's screen while dragging: the finger at `point` in a `bounds`-sized view (y down).
    public static func phoneExit(point p: CGPoint, velocity: CGVector, bounds: CGSize) -> (side: LinkSide, height: Double)? {
        exit(linkPhoneExit(point: point(p), dx: velocity.dx, dy: velocity.dy, width: bounds.width, height: bounds.height))
    }

    /// A throw when letting go: where the flick would carry the Imp (`predicted`) leaves the screen sideways.
    public static func phoneRelease(point p: CGPoint, predicted: CGPoint, velocity: CGVector, bounds: CGSize) -> (side: LinkSide, height: Double)? {
        exit(linkPhoneRelease(point: point(p), predicted: point(predicted), dx: velocity.dx, dy: velocity.dy,
                              width: bounds.width, height: bounds.height))
    }
}

/// Spots a throw with the whole phone: a sharp sideways jolt, fed the user acceleration along the x axis
/// (g, positive toward the right edge in portrait) many times a second. Several pushes back and forth
/// are a shake, not a throw.
public struct JoltDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case thrown(LinkSide)
        case shaken
    }

    private let core: LinkJoltDetector

    public init(threshold: Double = 2.0, window: TimeInterval = 0.45, shakeCount: Int = 4, cooldown: TimeInterval = 1.0) {
        core = LinkJoltDetector(threshold: threshold, window: window, shakeCount: UInt32(max(shakeCount, 1)), cooldown: cooldown)
    }

    /// The way the last shake began (its first push).
    public var shakeStart: LinkSide? { core.shakeStart().flatMap(LinkSide.init) }

    /// One sample. Returns a throw once the movement is over (no shake followed), or a shake.
    public mutating func feed(x: Double, at t: TimeInterval) -> Event? {
        switch core.feed(x: x, at: t) {
        case .thrown(let side): LinkSide(rawValue: side).map(Event.thrown)
        case .shaken: .shaken
        case nil: nil
        }
    }
}
