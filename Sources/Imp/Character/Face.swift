import CoreGraphics
import Foundation
import ImpKit

enum Mood: Equatable, CaseIterable {
    case idle, listening, thinking, happy, love, sad, error, sleepy, annoyed, surprised, dizzy, mean, working
    case content, giggly, scared, curious, shy, excited, bored

    /// Moods whose eyes are already shut or drawn as strokes: no blinking.
    var eyesClosed: Bool { [.happy, .love, .sleepy, .error, .dizzy, .content, .giggly].contains(self) }

    /// Moods that keep an eye on the cursor while nothing else steers the gaze.
    var watchesCursor: Bool { [.idle, .surprised, .annoyed, .curious, .scared, .excited].contains(self) }
}

/// Expression parameters. Imp has no pupils and no mouth: it feels with the silhouette of its
/// mochi head, the shape of its white eyes, which way its face is turned, and its little horns.
struct Face {
    // Head silhouette
    var headW = 1.0
    var headH = 1.0
    var square = 2.0          // superellipse exponent of the dome: 2 = round, 3 = boxy & tense
    var sag = 0.0             // cheeks melt out near the base (sad, sleepy, content)
    var peak = 0.0            // the top pulls into a little tuft (startled)
    var wobble = 0.0          // jelly ripple
    var tilt = 0.0            // degrees, around the base
    // Turn: the face slides over the head like on a ball (this is how Imp "looks").
    var lookX = 0.0           // yaw −1…1
    var lookY = 0.0           // pitch −1 (up)…1 (down)
    // Eyes (solid white)
    var eyeW = 1.0
    var eyeH = 1.0
    var lid = 0.0             // flat cut from the top: 0.5 = half-moon
    var slant = 0.0           // + angry (inner corners down), − worried (outer down)
    var squint = 0.0          // squint the left eye
    var arc = 0.0             // eyes become strokes: ^ ^ (bend +) or ‿ ‿ (bend −)
    var bend = 1.0
    var squeeze = 0.0         // > <
    var spiral = 0.0          // @ @ (dizzy)
    // Horns
    var horn = 0.0            // degrees: + perky (tips lean in), − droopy (tips lean out)
    var hornSize = 1.0
    /// Skin colour (see `Palette`). Springs like everything else, so a new colour blends in.
    var hue = 0.0
    // Extras
    var flush = 0.0
    var blush = 0.0
    var burst = 0.0           // little red tick marks ("!")
    var sparkle = 0.0
    var heart = 0.0
    var sleep = 0.0

    nonisolated(unsafe) static let fields: [WritableKeyPath<Face, Double>] = [
        \.headW, \.headH, \.square, \.sag, \.peak, \.wobble, \.tilt, \.lookX, \.lookY,
        \.eyeW, \.eyeH, \.lid, \.slant, \.squint, \.arc, \.bend, \.squeeze, \.spiral, \.horn, \.hornSize,
        \.hue, \.flush, \.blush, \.burst, \.sparkle, \.heart, \.sleep,
    ]

    init() {}

    init(_ mood: Mood) {
        switch mood {
        case .idle: break
        case .listening:
            headH = 1.05; headW = 0.97; peak = 0.15
            eyeH = 1.14; eyeW = 1.06; horn = 10; lookY = -0.15
        case .thinking:
            lookX = -0.55; lookY = -0.55; tilt = -6; lid = 0.3; slant = -0.12
            squint = 0.6; wobble = 0.2
        case .happy:
            arc = 1; blush = 1; sag = 0.5; headW = 1.06; headH = 0.94
            peak = 0.1; horn = 8; sparkle = 0.8
        case .love:
            arc = 1; blush = 1; sag = 0.35; headW = 1.04; headH = 0.96
            lookX = 0.3; tilt = 6; horn = 6; heart = 1
        case .sad:
            lid = 0.34; slant = -0.7; sag = 0.7; headW = 1.05; headH = 0.93
            horn = -20; lookY = 0.25; eyeH = 1.05
        case .error:
            squeeze = 1; headW = 1.07; headH = 0.91; sag = 0.3; burst = 0.7
            horn = -8; tilt = -4
        case .sleepy:
            arc = 1; bend = -1; sag = 0.6; headH = 0.88; headW = 1.08; lookY = 0.3
            horn = -14; sleep = 1
        case .annoyed:
            lid = 0.5; slant = 0.75; flush = 1; square = 2.6; headW = 1.04
            burst = 1; horn = 6; hornSize = 1.12; lookY = 0.1
        case .surprised:
            headH = 1.1; headW = 0.94; peak = 1; eyeW = 1.12; eyeH = 1.26
            horn = 16; hornSize = 1.05; burst = 1
        case .dizzy:
            spiral = 1; wobble = 0.45; sag = 0.3; headW = 1.03; headH = 0.96; horn = -10
        case .working:
            // Head down, busy with something just in front of it (commands and tools).
            lookX = 0.3; lookY = 0.5; lid = 0.16; eyeH = 0.92; headW = 1.02; horn = 6
        case .mean:
            // An unimpressed, lopsided glare: heavy lids, one eye narrower, no shouting.
            lid = 0.56; slant = 0.3; squint = 0.55; flush = 0.25; tilt = -4
            horn = 12; hornSize = 1.06; lookY = 0.05; headH = 0.97
        case .content:
            // Melting into a stroke: soft ^ ^ eyes, rosy cheeks, horns relaxed. Calmer than happy.
            arc = 1; bend = 0.55; blush = 1; sag = 0.6; headW = 1.07; headH = 0.93
            horn = -6; lookY = -0.1
        case .giggly:
            // Ticklish: eyes squeezed shut > <, cheeks pink, horns up.
            squeeze = 1; blush = 1; headW = 1.05; headH = 0.95; wobble = 0.3
            horn = 10; sparkle = 0.5
        case .scared:
            // Small and worried: narrow tall eyes, horns pinned back, ducking.
            eyeW = 0.72; eyeH = 1.08; lid = 0.16; slant = -0.6; horn = -26; hornSize = 0.95
            headH = 0.9; headW = 0.99; sag = 0.1; lookY = 0.15
        case .curious:
            // Head cocked, one eye wider, horns pricked.
            tilt = 10; squint = -0.6; eyeH = 1.08; peak = 0.35; horn = 12
            headH = 1.04; headW = 0.98; lookY = -0.1
        case .shy:
            // Looks away and down, smaller eyes, a deep blush.
            blush = 1; eyeH = 0.74; eyeW = 0.9; lid = 0.18; slant = -0.25
            lookX = 0.55; lookY = 0.45; tilt = 7; horn = -8; headH = 0.95; sag = 0.3
        case .excited:
            // Big bright eyes, sparkles, horns high, standing tall.
            eyeW = 1.12; eyeH = 1.2; sparkle = 1; peak = 0.5; horn = 18; hornSize = 1.06
            headH = 1.06; headW = 0.97; lookY = -0.15
        case .bored:
            // Flat, heavy lids, slumped, looking off to the side.
            lid = 0.55; eyeH = 0.95; sag = 0.45; headH = 0.94; headW = 1.05
            horn = -10; lookX = -0.45; lookY = 0.15; tilt = -4
        }
    }

    /// The settled face for a mood and gaze (renders, icons, previews).
    static func settled(_ mood: Mood, lookX: Double = 0, lookY: Double = 0) -> Face {
        var f = Face(mood)
        if lookX != 0 || lookY != 0 { f.lookX = lookX; f.lookY = lookY }
        return f
    }
}

/// Springs each face parameter toward its target: slightly bouncy, alive.
final class FaceAnimator {
    private(set) var face = Face()
    private var velocity = [Double](repeating: 0, count: Face.fields.count)
    private var last: TimeInterval?
    /// Whether every spring had come to rest after the last step (nothing left to draw).
    private(set) var isSettled = true

    private static let bend = Face.fields.firstIndex(of: \.bend)!

    func step(to target: Face, at t: TimeInterval, stiffness: Double = 210, damping: Double = 17) -> Face {
        let dt = min(1 / 20, max(0, t - (last ?? t)))
        last = t
        guard dt > 0 else { return face }
        // Stroke eyes (^ ^ or ‿ ‿) only change shape while they show. Otherwise the bend swung
        // through a flat line on the way in or out of sleep, drawn over the opening eyes.
        var target = target
        if target.arc < 0.01 { target.bend = face.bend }        // fading out: keep the shape
        if face.arc < 0.3 {                                     // not visible yet: take the shape at once
            face.bend = target.bend
            velocity[Self.bend] = 0
        }
        for (i, k) in Face.fields.enumerated() {
            let x = face[keyPath: k]
            let v = velocity[i] + ((target[keyPath: k] - x) * stiffness - velocity[i] * damping) * dt
            velocity[i] = v
            face[keyPath: k] = x + v * dt
        }
        isSettled = SpringSettle.isSettled(values: Face.fields.map { face[keyPath: $0] },
                                           targets: Face.fields.map { target[keyPath: $0] }, velocities: velocity)
        return face
    }
}
