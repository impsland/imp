import CoreGraphics
import Foundation
import ImpKit

/// Turns what an Imp is up to into the face and body to draw for one frame. Shared by the
/// desktop Imp (`ImpView`) and the figures in the window (`StageImp`), so they move alike.
///
/// Everything changes smoothly: the face springs toward its target (`FaceAnimator`), and when the
/// mood changes, its body motion (a happy bounce, a scared shiver, a dizzy sway) cross-fades into
/// the next one instead of stopping dead, however often the mood changes.
final class Puppet {
    /// What to act out this frame.
    struct Cue {
        var mood: Mood
        /// The beat of an animation being played, if any.
        var step: AnticStep?
        var hue: Double
        /// Where to look when neither the mood nor the beat decides (the cursor, a friend): a
        /// head turn, −1…1 each way. Nil: straight ahead.
        var gaze: CGPoint?
        /// Watching another Imp: horns perked, all ears.
        var attentive = false
        /// Extra tilt in degrees (swinging while it's carried).
        var lean = 0.0
        /// Microphone loudness while listening.
        var level = 0.0
        /// Breathing is drawn here (false when Core Animation breathes for the Imp).
        var breathing = true
        /// Seconds since a hop started.
        var hopSince: Double?
        /// Its character, laid over every face (see `ImpTraits`).
        var traits = ImpTraits.plain
    }

    /// How long one mood's motion takes to fade into the next.
    static let blend = 0.35

    private let animator = FaceAnimator()
    private var moods = BlendWeights<Mood>(duration: Puppet.blend)

    /// Nothing is moving toward a new pose (no spring under way, no motion fading).
    var isSettled: Bool { animator.isSettled && moods.isSettled }

    func frame(_ cue: Cue, at t: TimeInterval) -> (face: Face, motion: Motion) {
        moods.advance(to: cue.mood, at: t)
        let face = animator.step(to: Self.target(cue), at: t)
        // Every mood still fading in or out contributes by its weight, so a mood that changes
        // again mid-blend never makes the body jump.
        let parts = moods.mix.map { (Motion.at(t, mood: $0.key, level: cue.level, breathing: cue.breathing), $0.weight) }
        var motion = parts.count == 1 ? parts[0].0 : Motion.blend(parts, at: t)
        if let since = cue.hopSince { motion.hop(since: since) }
        return (face, motion)
    }

    /// The face to spring toward.
    static func target(_ cue: Cue) -> Face {
        var f = Face(cue.mood)
        f.hue = cue.hue
        if let look = cue.step?.look {
            f.lookX = look.x
            f.lookY = look.y
        } else if let gaze = cue.gaze, cue.mood.watchesCursor {
            f.lookX = gaze.x
            f.lookY = gaze.y
            if cue.attentive {
                f.horn += 8
                f.eyeH *= 1.05
            }
        }
        if let step = cue.step {
            f.tilt += step.tilt
            f.headH *= 1 + step.stretch
            f.headW *= 1 - step.stretch * 0.6
        }
        f.tilt += cue.lean
        apply(cue.traits, to: &f)
        return f
    }

    /// Lays an Imp's character over a face: lids, brows, eye size and horns, in every mood.
    static func apply(_ t: ImpTraits, to f: inout Face) {
        guard t != .plain else { return }
        f.lid = min(0.9, f.lid + t.lids * (1 - f.lid))
        f.slant += t.slant * 0.6
        f.eyeW *= 1 + t.eyes
        f.eyeH *= 1 + t.eyes
        f.squint = max(-1, min(1, f.squint + t.squint * 0.6))
        f.horn += t.horns
        f.blush = max(f.blush, t.blush)
        f.tilt += t.tilt
    }
}
