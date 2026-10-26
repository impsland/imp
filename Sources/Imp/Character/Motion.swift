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

    /// A mix of two motions: `k` 0 is all `a`, 1 is all `b`.
    static func mix(_ a: Motion, _ b: Motion, _ k: Double) -> Motion {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        return Motion(t: b.t, blink: l(a.blink, b.blink), bob: l(a.bob, b.bob), squash: l(a.squash, b.squash),
                      shakeX: l(a.shakeX, b.shakeX), tilt: l(a.tilt, b.tilt), hornL: l(a.hornL, b.hornL),
                      hornR: l(a.hornR, b.hornR), ripple: l(a.ripple, b.ripple))
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
            bob -= 15 * sin(k * .pi)
            squash += 0.09 * release - 0.07 * sin(min(1, k / 0.5) * .pi) * (1 - release)
        default:                                        // land
            squash += 0.1 * sin((since - 0.56) / 0.19 * .pi)
        }
    }

    static let hopLength = 0.75

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
