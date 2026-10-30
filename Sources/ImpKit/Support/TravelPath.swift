import CoreGraphics
import Foundation

/// How an Imp gets somewhere on screen (`imp_move`).
public enum Travel: String, CaseIterable, Sendable {
    /// One leap in an arc.
    case hop
    /// A glide, leaning into it.
    case slide
    /// A few bounces, smaller each time, like a ball.
    case bounce
    /// A big, quick leap.
    case jump
}

/// The way from one spot to another: where the Imp's window is at each moment of the journey, and
/// how far it leans. Starts and ends exactly at the two spots.
public struct TravelPath: Sendable {
    public let from: CGPoint
    public let to: CGPoint
    public let travel: Travel
    /// The Imp's size (points): arcs and speeds scale with it.
    public let size: CGFloat
    /// Seconds the journey takes.
    public let duration: Double

    public init(from: CGPoint, to: CGPoint, _ travel: Travel, size: CGFloat) {
        self.from = from; self.to = to; self.travel = travel; self.size = size
        let d = Double(hypot(to.x - from.x, to.y - from.y))
        duration = switch travel {
        case .hop: min(1.1, max(0.45, 0.35 + d / 1400))
        case .jump: min(0.8, max(0.35, 0.3 + d / 2400))
        case .slide: min(1.6, max(0.4, 0.3 + d / 900))
        case .bounce: min(2.2, max(0.9, 0.6 + d / 700))
        }
    }

    public var distance: Double { Double(hypot(to.x - from.x, to.y - from.y)) }

    /// Where the window is `k` (0…1) of the way along, and its lean in degrees (it leans into a slide).
    public func at(_ k: Double) -> (origin: CGPoint, lean: Double) {
        let k = min(max(k, 0), 1)
        let dx = Double(to.x - from.x), dy = Double(to.y - from.y)
        func point(_ t: Double, lift: Double) -> CGPoint {
            CGPoint(x: Double(from.x) + dx * t, y: Double(from.y) + dy * t + lift)
        }
        switch travel {
        case .slide:
            // Ease in and out; lean forward while speeding up, back while slowing down.
            let t = k * k * (3 - 2 * k)
            let speed = 6 * k * (1 - k)                       // d(smoothstep)/dk, 0…1.5
            // Leans the way it's going while it speeds up, and back a little as it stops.
            let lean = (dx < 0 ? -1 : 1) * min(10, speed * 7) * (k < 0.5 ? 1 : -0.4)
            return (point(t, lift: 0), dx.magnitude < 1 ? 0 : lean)
        case .hop, .jump:
            let height = (travel == .jump ? 1.6 : 0.8) * Double(size) + distance * (travel == .jump ? 0.25 : 0.15)
            return (point(0.5 - cos(k * .pi) / 2, lift: height * sin(k * .pi)), 0)
        case .bounce:
            // Three bounces along the way, each lower and shorter than the last.
            let spans = [0.45, 0.33, 0.22]
            let heights = [0.9, 0.45, 0.2].map { $0 * Double(size) + distance * 0.06 }
            var start = 0.0
            for (i, span) in spans.enumerated() {
                if k <= start + span || i == spans.count - 1 {
                    let local = min(1, (k - start) / span)
                    return (point(k, lift: heights[i] * sin(local * .pi)), 0)
                }
                start += span
            }
            return (point(k, lift: 0), 0)
        }
    }
}

/// An Imp thrown over from the iPhone, coming onto the desktop: it sails in from past the side at
/// the speed it was thrown and brakes to a stop, as it does on the phone. It keeps the height it
/// was thrown at, with only a slight rise mid-flight, and leans into the flight until it slows.
public struct GlidePath: Sendable {
    public let from: CGPoint
    public let to: CGPoint
    /// Seconds the glide takes.
    public let duration: Double
    /// How hard it brakes: the speed falls by e^-braking over the glide.
    static let braking = 4.0

    /// `speed`: the throw's sideways speed (points a second). Zero (sent from a menu) is a gentle push.
    public init(from: CGPoint, to: CGPoint, speed: Double) {
        self.from = from; self.to = to
        let v = min(max(speed.isFinite && speed > 0 ? speed : 900, 900), 2_600)
        // It sets off at the throw's speed: the eased curve's starting slope is braking / (1 - e^-braking).
        let a = Self.braking
        let distance = Double(hypot(to.x - from.x, to.y - from.y))
        duration = min(1.5, max(0.65, distance * a / (1 - exp(-a)) / v))
    }

    /// Where the window is `k` (0…1) of the way through the glide, and its lean in degrees.
    public func at(_ k: Double) -> (origin: CGPoint, lean: Double) {
        let k = min(max(k, 0), 1)
        let a = Self.braking
        let t = (1 - exp(-a * k)) / (1 - exp(-a))                 // fast at first, braking to a stop
        let dx = Double(to.x - from.x), dy = Double(to.y - from.y)
        let rise = min(14, 0.1 * abs(dx)) * sin(t * .pi)           // a slight sail, back to its height
        let origin = CGPoint(x: Double(from.x) + dx * t, y: Double(from.y) + dy * t + rise)
        guard abs(dx) >= 1 else { return (origin, 0) }
        let direction: Double = dx < 0 ? -1 : 1
        // Leans forward while it's fast, then rocks back a little as it stops.
        let forward = 12 * (exp(-a * k) - exp(-a)) / (1 - exp(-a)) * sin(min(1, k * 8) * .pi / 2)
        let settle = k > 0.7 ? 3 * sin((k - 0.7) / 0.3 * .pi) : 0
        return (origin, direction * (forward - settle))
    }
}
