import Foundation

/// Per-frame motion layered over the expression: breathing, blinks, horn wiggles, bouncing to your voice.
struct Motion {
    var t: TimeInterval = 0
    var blink = 0.0         // 0 open … 1 closed
    var bob = 0.0           // vertical offset
    var squash = 0.0        // + squash, − stretch
    var shakeX = 0.0
    var tilt = 0.0          // extra degrees on top of the face's tilt
    var hornL = 0.0         // extra degrees
    var hornR = 0.0
    var ripple = 0.0        // extra outline wobble (voice)
    /// How high a hop has lifted it (design units, up +). Apart from `bob`, so the drawing can
    /// lower a hop that would carry a tall pose out of the top of its frame.
    var lift = 0.0
    /// A turn round its own (upright) axis, radians on top of where it looks: the face goes round
    /// the back of the ball and comes back from the other side (see `Pose`).
    var spin = 0.0
    /// A turn over the top (radians, + forward), like a somersault.
    var pitch = 0.0
    /// A whole-body turn in the picture's plane (degrees, + clockwise) round the middle of the
    /// body, like a cartwheel (apart from `tilt`, which pivots at the base).
    var roll = 0.0

    /// The resting breath (see `breath(at:)`). Off when Core Animation breathes for Imp.
    static func at(_ t: TimeInterval, mood: Mood, level: Double, breathing: Bool = true) -> Motion {
        var m = Motion(t: t)
        if breathing { (m.bob, m.squash) = breath(at: t) }
        if !mood.eyesClosed { m.blink = blink(at: t) }
        switch mood {
        case .thinking:
            m.hornL = sin(t * 5.5) * 8
            m.hornR = -m.hornL
        case .listening:
            m.hornL = sin(t * 31) * level * 7
            m.hornR = sin(t * 29 + 1) * level * 7
            m.bob -= level * 2.5
            m.squash -= level * 0.06
            m.ripple = level * 0.8
        case .happy, .love:
            let b = abs(sin(t * 7))
            m.bob -= b * 3.5
            m.squash = (1 - b) * 0.08 - 0.02
            m.hornL = sin(t * 14) * 5
            m.hornR = -m.hornL
        case .annoyed:
            m.shakeX = sin(t * 48) * 1.2
        case .error:
            m.shakeX = sin(t * 30) * 0.8
            m.squash = 0.05
        case .surprised:
            m.bob -= 2.5
            m.squash = -0.05
        case .sleepy:
            m.bob = sin(t * 0.9)
            m.squash = 0.03 + sin(t * 0.9) * 0.03
        case .sad:
            m.squash = 0.04
        case .dizzy:
            m.tilt = sin(t * 3.2) * 9
            m.shakeX = sin(t * 3.2 + 1.2) * 1.4
            m.hornL = sin(t * 3.2) * 6
            m.hornR = m.hornL
        case .mean:
            m.squash = 0.02
        case .working:
            let tap = abs(sin(t * 9))
            m.bob -= tap * 1.1
            m.hornL = sin(t * 9) * 4
            m.hornR = -m.hornL
        case .content:
            // A slow, purring sway: the outline trembles a little.
            m.tilt = sin(t * 2.2) * 3
            m.ripple = 0.12
            m.hornL = sin(t * 2.2) * 3
            m.hornR = m.hornL
        case .giggly:
            let b = abs(sin(t * 11))
            m.bob -= b * 2.5
            m.squash = (1 - b) * 0.06 - 0.02
            m.tilt = sin(t * 9) * 4
        case .scared:
            m.shakeX = sin(t * 55) * 0.9
            m.squash = 0.05
            m.bob += 1
            m.hornL = sin(t * 40) * 2
            m.hornR = -m.hornL
        case .curious:
            m.tilt = sin(t * 1.6) * 2.5
            m.hornL = max(0, sin(t * 3)) * 6                    // one horn twitches
        case .shy:
            m.shakeX = sin(t * 2.5) * 0.8
            m.squash = 0.02
        case .excited:
            let b = abs(sin(t * 9))
            m.bob -= b * 4
            m.squash = (1 - b) * 0.07 - 0.03
            m.hornL = sin(t * 18) * 6
            m.hornR = -m.hornL
        case .bored:
            m.squash = 0.03
        case .idle:
            break
        }
        return m
    }

    /// A weighted mix of motions (weights sum to 1), at time `t`.
    static func blend(_ parts: [(motion: Motion, weight: Double)], at t: TimeInterval) -> Motion {
        var m = Motion(t: t)
        for (p, w) in parts {
            m.blink += p.blink * w
            m.bob += p.bob * w
            m.squash += p.squash * w
            m.shakeX += p.shakeX * w
            m.tilt += p.tilt * w
            m.hornL += p.hornL * w
            m.hornR += p.hornR * w
            m.ripple += p.ripple * w
            m.lift += p.lift * w
            m.spin += p.spin * w
            m.pitch += p.pitch * w
            m.roll += p.roll * w
        }
        return m
    }

    /// The slow resting breath: (bob, squash). Shared with the Core Animation version of it.
    static func breath(at t: TimeInterval) -> (bob: Double, squash: Double) {
        let b = sin(t * breathRate)
        return (b * 0.7, b * 0.016)
    }

    static let breathRate = 1.7

    /// The next moment a blink is under way, at or after `t` (blinks are deterministic).
    static func nextBlink(after t: TimeInterval) -> TimeInterval {
        var x = t
        while x < t + 10 {
            if blink(at: x) > 0 { return x }
            x += 1 / 60
        }
        return t + 10
    }

    /// A hop `since` seconds ago: crouch, spring up, land with a squish. Every phase starts
    /// where the last one ended, so the body never pops from squashed to stretched in a frame.
    mutating func hop(since: Double) {
        guard since >= 0, since < Self.hopLength else { return }
        switch since {
        case ..<0.12:                                   // crouch
            squash += 0.09 * sin(since / 0.12 * .pi / 2)
        case ..<0.56:                                   // airborne: the crouch springs into a stretch, then rounds out
            let k = (since - 0.12) / 0.44
            let release = 1 - Self.smooth(k / 0.2)
            lift += Self.hopHeight * sin(k * .pi)
            squash += 0.09 * release - 0.07 * sin(min(1, k / 0.5) * .pi) * (1 - release)
        default:                                        // land
            squash += 0.1 * sin((since - 0.56) / 0.19 * .pi)
        }
    }

    /// A beat's move, `elapsed` seconds into a beat `duration` long (see `BodyMove`). Every move
    /// starts and ends at rest, so beats before and after it join without a jump.
    mutating func perform(_ move: BodyMove, elapsed: Double, duration: Double) {
        guard duration > 0 else { return }
        let p = max(0, min(1, elapsed / duration))
        let n = Double(move.times), dir = move.reverse ? -1.0 : 1.0
        let arc = sin(p * .pi)                       // 0 → 1 → 0 over the beat
        let wave = sin(p * n * 2 * .pi)              // n full swings, 0 at both ends
        switch move.kind {
        case .spin:
            spin += dir * n * 2 * .pi * Self.ease(p)
            squash -= 0.05 * arc                     // stands a little taller while it turns
        case .flip:
            pitch += dir * n * 2 * .pi * Self.ease(p)
            lift += Self.hopHeight * 1.2 * arc
            squash += 0.06 * Self.edge(p) - 0.05 * arc
        case .roll:
            roll += dir * n * 360 * Self.ease(p)
            lift += Self.hopHeight * 1.1 * pow(arc, 0.6)
        case .bounce:
            let k = (p * n).truncatingRemainder(dividingBy: 1)
            let up = sin(k * .pi)
            lift += Self.hopHeight * 0.75 * up
            // Stretched in the air, squished as it lands (not at the very start or end).
            squash += (0.08 * pow(1 - up, 6) - 0.05 * up) * pow(arc, 0.35)
        case .shake:
            shakeX += dir * 3.2 * wave
            tilt += dir * 2.5 * wave
        case .sway:
            tilt += dir * 13 * wave
            shakeX += dir * 1.2 * wave
        case .wobble:
            squash += 0.13 * wave * (1 - p)
            ripple += 0.7 * arc
        case .float:
            let rise = Self.smooth(p / 0.25) * Self.smooth((1 - p) / 0.25)
            lift += (Self.hopHeight * 0.9 + 2.5 * wave) * rise
            squash -= 0.03 * rise
        case .nod:
            let k = sin(p * n * .pi)
            pitch += 0.55 * k * k
        case .headshake:
            spin += dir * 0.6 * wave * pow(arc, 0.5)
        }
    }

    /// Slow in, slow out: a turn that winds up and settles instead of starting and stopping dead.
    static func ease(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
    }

    /// A crouch at the very start and end of a beat, for take-offs and landings.
    private static func edge(_ p: Double) -> Double { max(0, 1 - min(p, 1 - p) / 0.12) * min(1, min(p, 1 - p) / 0.04) }

    static let hopLength = 0.75
    static let hopHeight = 15.0

    /// Whether a hop may start now, `since` seconds after the last one began. One still in the
    /// air isn't restarted: that would teleport the body from mid-jump back to the ground.
    static func canHop(since: Double) -> Bool { since >= hopLength }

    /// Smoothstep: 0 → 1 with zero slope at both ends.
    static func smooth(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k * k * (3 - 2 * k)
    }

    /// Deterministic, natural-looking blinks every ~2.5–6 s, with occasional doubles.
    static func blink(at t: TimeInterval) -> Double {
        let period = 4.3, duration = 0.16
        let cycle = floor(t / period)
        let r = (sin(cycle * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude
        let p = t - (cycle * period + r * (period - 0.6))
        if p >= 0 && p < duration { return sin(p / duration * .pi) }
        if r > 0.8, p >= 0.24, p < 0.24 + duration { return sin((p - 0.24) / duration * .pi) }
        return 0
    }
}

/// A move a beat plays across its whole length (`AnimationBeat.moves`).
struct BodyMove: Equatable {
    enum Kind: String, CaseIterable {
        case spin, flip, roll, bounce, shake, sway, wobble, float, nod, headshake
    }

    var kind: Kind
    /// Turns, bounces, shakes…
    var times = 1
    /// The other way round.
    var reverse = false
}
