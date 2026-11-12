import CoreGraphics
import Foundation

/// Recognises playful cursor movements around an Imp from a stream of cursor samples (screen
/// coordinates, y up), and what a resting cursor means.
///
/// Every gesture asks for something deliberate, so just passing by, or heading for the Imp to
/// drag it, never sets one off:
///  - stroke: slow strokes to and fro on its head, at least three turns spread over ~a second.
///    Once petting, each further stroke reports `.stroke` again, so the Imp enjoys it for as long
///    as you keep going.
///  - tickle: quick, small jiggles on its head (five turns within a second).
///  - swish: wide swishes left-right-left across its face. circle: two laps around it.
///  - dangle: bobbing up and down just above its head.
///  - rush: arriving on it from far away within a split second.
///  - stare / linger (see `rest(at:center:radius:)`): resting on its face, or just beside it.
/// Pressing the Imp (`pressed()`) silences all of these until the cursor has left its head, so a
/// cursor left on it after a click or drag isn't taken for a stare or a stroke.
public struct MouseGestures {
    private struct Sample { var p: CGPoint; var t: TimeInterval }

    private var last: Sample?
    private var trail: [Sample] = []
    // Circling
    private var lastAngle: Double?
    private var spins: [(t: TimeInterval, delta: Double)] = []
    // Swings
    private var swish = Oscillation(window: 1.6)
    private var bob = Oscillation(window: 2.0)
    private var strokeX = Oscillation(window: 3.0)
    private var strokeY = Oscillation(window: 3.0)
    private var tickle = Oscillation(window: 1.0)
    /// A stroke has been recognised and is still going on.
    private var petting = false
    /// Pressed: nothing counts until the cursor leaves the head.
    private var heldOff = false
    /// The current rest was already reported.
    private var restReported = false

    public static let turnsForDizzy = 2.0
    /// Seconds the cursor rests on the face before the Imp feels stared at.
    public static let stareAfter: TimeInterval = 1.5
    /// Seconds the cursor rests beside the Imp before it gets curious.
    public static let lingerAfter: TimeInterval = 2.5
    /// A pause this long ends any gesture.
    static let pause: TimeInterval = 0.5

    public init() {}

    /// Feeds a cursor position. `center` and `radius` describe the Imp's head on screen.
    public mutating func move(to p: CGPoint, at t: TimeInterval, center c: CGPoint, radius r: CGFloat) -> AnimationTrigger? {
        if let last, t - last.t > Self.pause { reset() }
        defer { last = Sample(p: p, t: t) }
        restReported = false
        let dx = p.x - c.x, dy = p.y - c.y
        let d = hypot(dx, dy)
        if heldOff {
            guard d > r * 1.4 else { return nil }
            heldOff = false
        }
        trail.append(Sample(p: p, t: t))
        trail.removeAll { t - $0.t > 1.6 }

        let gesture = rushed(d: d, at: t, center: c, r: r)
            ?? circling(angle: atan2(dy, dx), inRange: d > r * 0.7 && d < r * 5, at: t)
            ?? waving(p, at: t, inFront: abs(dx) < r * 3 && dy > -r && dy < r * 1.6, r: r)
            ?? dangling(p, at: t, above: abs(dx) < r * 1.6 && dy > r * 0.9 && dy < r * 4, r: r)
            ?? onHead(p, at: t, r: r, inside: d < r * 1.05 && dy > -r * 0.5)
        // One-off gestures start over; petting goes on for as long as the strokes do.
        if let gesture, gesture != .stroke { reset() }
        return gesture
    }

    /// Call while the cursor may be resting (a few times a second). Reports a stare (resting on
    /// the face) or a linger (resting just beside it), once per rest.
    public mutating func rest(at t: TimeInterval, center c: CGPoint, radius r: CGFloat) -> AnimationTrigger? {
        guard let last, !restReported, !heldOff else { return nil }
        let still = t - last.t
        let d = hypot(last.p.x - c.x, last.p.y - c.y)
        let gesture: AnimationTrigger? = if d < r * 0.9 && still >= Self.stareAfter {
            .stare
        } else if d > r * 1.25 && d < r * 3.2 && still >= Self.lingerAfter {
            .linger
        } else {
            nil
        }
        if gesture != nil { restReported = true }
        return gesture
    }

    /// The Imp was pressed (a click, a hold, a drag): hover gestures wait until the cursor has
    /// left it.
    public mutating func pressed() {
        reset()
        heldOff = true
        restReported = true
    }

    public mutating func reset() {
        trail = []
        lastAngle = nil; spins = []
        swish.reset(); bob.reset()
        strokeX.reset(); strokeY.reset(); tickle.reset()
        petting = false
    }

    // MARK: Gestures

    /// Arrived on its head from at least six head-widths away within 0.15 s.
    private func rushed(d: CGFloat, at t: TimeInterval, center c: CGPoint, r: CGFloat) -> AnimationTrigger? {
        guard d < r * 1.3, let from = trail.first(where: { t - $0.t <= 0.15 }) else { return nil }
        return hypot(from.p.x - c.x, from.p.y - c.y) > r * 6 ? .rush : nil
    }

    private mutating func circling(angle a: Double, inRange: Bool, at t: TimeInterval) -> AnimationTrigger? {
        guard inRange else { lastAngle = nil; spins = []; return nil }
        if let l = lastAngle { spins.append((t, remainder(a - l, 2 * .pi))) }
        lastAngle = a
        spins.removeAll { t - $0.t > 4 }
        return abs(spins.reduce(0) { $0 + $1.delta }) >= Self.turnsForDizzy * 2 * .pi ? .circle : nil
    }

    private mutating func waving(_ p: CGPoint, at t: TimeInterval, inFront: Bool, r: CGFloat) -> AnimationTrigger? {
        guard inFront else { swish.reset(); return nil }
        swish.add(p.x, at: t, minSwing: max(24, r * 0.6))
        guard swish.count >= 3 else { return nil }
        // Mostly sideways (a swish, not a circle) and across the whole face (not petting).
        let (w, h) = extent(since: t - swish.window)
        return h < 0.6 * w && w > r * 1.6 ? .swish : nil
    }

    private mutating func dangling(_ p: CGPoint, at t: TimeInterval, above: Bool, r: CGFloat) -> AnimationTrigger? {
        guard above else { bob.reset(); return nil }
        bob.add(p.y, at: t, minSwing: max(12, r * 0.3))
        guard bob.count >= 3 else { return nil }
        let (w, h) = extent(since: t - 1.2)
        return w < 0.8 * h ? .dangle : nil                       // up and down, not around
    }

    /// Tickling (quick jiggles) or petting (slow strokes), on the head.
    private mutating func onHead(_ p: CGPoint, at t: TimeInterval, r: CGFloat, inside: Bool) -> AnimationTrigger? {
        guard inside, let last else {
            strokeX.reset(); strokeY.reset(); tickle.reset(); petting = false
            return nil
        }
        tickle.add(p.x, at: t, minSwing: max(4, r * 0.1))
        if tickle.count >= 5 { return .tickle }

        let speed = hypot(p.x - last.p.x, p.y - last.p.y) / max(0.001, t - last.t)
        guard speed < 900 else { strokeX.reset(); strokeY.reset(); petting = false; return nil }   // a flick, not a stroke
        let swing = r * 0.4
        let turnedX = strokeX.add(p.x, at: t, minSwing: swing)
        let turnedY = strokeY.add(p.y, at: t, minSwing: swing)
        let turned = turnedX || turnedY
        if petting { return turned ? .stroke : nil }
        // Three turns spread over most of a second: unhurried strokes, not a jiggle.
        let slow = [strokeX, strokeY].contains { ($0.span(ofLast: 3) ?? 0) >= 0.7 }
        guard turned, slow else { return nil }
        petting = true
        return .stroke
    }

    /// Width and height of the path the cursor took since `start`.
    private func extent(since start: TimeInterval) -> (CGFloat, CGFloat) {
        let recent = trail.filter { $0.t >= start }
        guard let first = recent.first else { return (0, 0) }
        var minX = first.p.x, maxX = first.p.x, minY = first.p.y, maxY = first.p.y
        for s in recent {
            minX = min(minX, s.p.x); maxX = max(maxX, s.p.x)
            minY = min(minY, s.p.y); maxY = max(maxY, s.p.y)
        }
        return (maxX - minX, maxY - minY)
    }
}

/// What pressing and carrying an Imp means: a press held still is a cuddle, a drag carries it,
/// and shaking it while you carry it is a shake.
public struct PressGestures {
    /// Seconds a press must be held, without moving, to become a hold.
    public static let holdAfter: TimeInterval = 0.6
    private var shakeX = Oscillation(window: 1.2)
    private var shakeY = Oscillation(window: 1.2)
    private var shaken = false

    public init() {}

    /// The Imp was dragged to `p`. True once per carry, when the drag becomes a shake (four
    /// quick turns either way).
    public mutating func drag(to p: CGPoint, at t: TimeInterval) -> Bool {
        guard !shaken else { return false }
        shakeX.add(p.x, at: t, minSwing: 30)
        shakeY.add(p.y, at: t, minSwing: 30)
        shaken = shakeX.count >= 4 || shakeY.count >= 4
        return shaken
    }
}
