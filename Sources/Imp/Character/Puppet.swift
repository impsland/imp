import CoreGraphics
import Foundation

/// Turns what an Imp is up to into the face and body to draw for one frame. Shared by the
/// desktop Imp (`ImpView`) and the figures in the window (`StageImp`), so they move alike.
///
/// Everything changes smoothly: the face springs toward its target (`FaceAnimator`), and when the
/// mood changes, its body motion (a happy bounce, a scared shiver, a dizzy sway) cross-fades into
/// the next one instead of stopping dead.
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
    }

    /// How long one mood's motion takes to fade into the next.
    static let blend = 0.35

    private let animator = FaceAnimator()
    private var mood: Mood?
    private var previous = Mood.idle
    private var changedAt = -Double.infinity
    private var last = 0.0

    /// Nothing is moving toward a new pose (no spring under way, no motion fading).
    var isSettled: Bool { animator.isSettled && last - changedAt >= Self.blend }

    func frame(_ cue: Cue, at t: TimeInterval) -> (face: Face, motion: Motion) {
        last = t
        if cue.mood != mood {
            previous = mood ?? cue.mood
            mood = cue.mood
            changedAt = t
        }
        let face = animator.step(to: Self.target(cue), at: t)
        let now = Motion.at(t, mood: cue.mood, level: cue.level, breathing: cue.breathing)
        let k = Motion.smooth((t - changedAt) / Self.blend)
        var motion = k < 1 ? Motion.mix(Motion.at(t, mood: previous, level: cue.level, breathing: cue.breathing), now, k) : now
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
        return f
    }
}
