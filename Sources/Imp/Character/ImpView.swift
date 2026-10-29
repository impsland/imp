import AppKit
import ImpKit
import SwiftUI

/// The live, animated Imp on the desktop.
struct ImpView: View {
    let model: ImpModel
    @State private var puppet = Puppet()
    @State private var settling = SettleWatch()

    var body: some View {
        let life = model.life
        let pace = FrameSchedule.pace(mood: model.mood(at: Date()),
                                      quiet: model.level < 0.01 && life.antic == nil && model.activity == nil && !life.lively,
                                      onScreen: model.isOnScreen)
        let clock = model.clock
        TimelineView(FrameSchedule(pace: pace, frame: Energy.shared.frame, clock: clock, settling: settling)) { timeline in
            let date = timeline.date
            let (face, motion) = puppet.frame(cue(at: date, breathing: pace != .resting), at: clock.time(date))
            let _ = settling.moving = !puppet.isSettled
            // The animation's glyph first. Otherwise what Imp is busy with (⚙︎ tools).
            let glyph = life.glyph(at: date)
                ?? model.activity?.glyph.map { ($0, date.timeIntervalSince(model.activitySince), Double.infinity) }
            Canvas { ctx, size in
                ImpRenderer.draw(&ctx, size: size, face: face, motion: motion, glyph: glyph?.0,
                                 glyphAge: glyph?.1 ?? 0, glyphFade: (glyph?.2 ?? 0) / 0.5)
            }
        }
        .onChange(of: pace == .resting, initial: true) { _, resting in model.onRestingChange?(resting) }
        .accessibilityLabel("Imp")
    }

    private func cue(at date: Date, breathing: Bool) -> Puppet.Cue {
        let mood = model.mood(at: date)
        let step = model.life.step
        var cue = Puppet.Cue(mood: mood, step: step, hue: model.profile.hue, lean: model.carryLean,
                             level: model.level, breathing: breathing,
                             hopSince: date.timeIntervalSince(model.life.hopAt),
                             stepElapsed: step == nil ? nil : date.timeIntervalSince(model.life.stepStarted), traits: model.profile.traits)
        if step == nil, mood == .idle, let friend = model.app.stage.focus(for: model) {
            // Another Imp is on stage: watch it.
            cue.gaze = Gaze.toward(friend, from: model.impCenter)
            cue.attentive = true
        } else {
            cue.gaze = Gaze.toward(NSEvent.mouseLocation, from: model.impCenter)
        }
        return cue
    }
}

/// When to draw a frame. Most of Imp's CPU is per-frame overhead (SwiftUI layout, layer
/// commits), not drawing, so the win is drawing fewer frames:
///  - lively: 60 fps while anything moves.
///  - drowsy: 12 fps (dozing: slow breath and floating z's).
///  - resting: no frames at all, except brief 60 fps bursts for blinks (they're deterministic,
///    see `Motion.blink`). The breath itself is a Core Animation loop on the panel's layer
///    (`ImpHostingView.setBreathing`), which runs outside the app.
/// Whatever the pace, frames keep coming at 60 fps until the face's springs have settled
/// (`settling`): the moment an animation ends Imp is already "quiet", but its head is still
/// turning back to the cursor, and drawing that turn only at blinks made it jerk.
struct FrameSchedule: TimelineSchedule {
    enum Pace { case lively, drowsy, resting, hidden }
    var pace: Pace
    /// Seconds between frames while moving (longer in Low Power Mode).
    var frame = Energy.fullFrame
    /// Whose blinks to wake up for.
    var clock = BodyClock.shared
    /// Set by the view after each frame; read as the next frame is scheduled.
    var settling = SettleWatch()

    /// How often a view in an unseen window looks again; it is woken sooner when it comes into view.
    static let hiddenCheck: TimeInterval = 10

    static func pace(mood: Mood, quiet: Bool, onScreen: Bool) -> Pace {
        guard onScreen else { return .hidden }
        guard quiet else { return .lively }
        return switch mood {
        case .idle: .resting
        case .sleepy: .drowsy
        default: .lively
        }
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(date: start, pace: mode == .lowFrequency && pace != .hidden ? .drowsy : pace, frame: frame,
                offset: clock.offset, settling: settling)
    }

    struct Entries: Sequence, IteratorProtocol {
        var date: Date
        let pace: Pace
        let frame: Double
        let offset: TimeInterval
        let settling: SettleWatch

        mutating func next() -> Date? {
            let t = date.timeIntervalSinceReferenceDate + offset
            let paced: Double = switch pace {
            case .lively: frame
            case .hidden: FrameSchedule.hiddenCheck
            case .drowsy: 1 / 12
            case .resting:
                // Mid-blink: keep going. Otherwise sleep until just before the next one
                // (at most a second, so slow state changes are still noticed).
                Motion.blink(at: t) > 0 || Motion.blink(at: t + 1 / 60) > 0
                    ? frame : Swift.min(1, Swift.max(frame, Motion.nextBlink(after: t) - t - frame))
            }
            let step = settling.moving && pace != .hidden ? frame : paced
            date = date.addingTimeInterval(step)
            return date
        }
    }
}

/// Whether the face is still moving toward its target. A reference, so the schedule sees what the
/// last frame found without the view having to change (main thread only).
final class SettleWatch: @unchecked Sendable {
    var moving = false
}

enum Gaze {
    /// Head turn (−1…1 each axis) toward a screen point. Saturates ~220 pt away.
    static func toward(_ p: CGPoint, from c: CGPoint) -> CGPoint {
        let dx = p.x - c.x, dy = c.y - p.y
        let d = max(1, hypot(dx, dy))
        let k = min(1, d / 220)
        return CGPoint(x: dx / d * k, y: dy / d * k)
    }
}

/// A still Imp (menu header, icons).
struct ImpPortrait: View {
    var face: Face
    var shadow = true

    var body: some View {
        Canvas { ctx, size in
            ImpRenderer.draw(&ctx, size: size, face: face, motion: Motion(), shadow: shadow)
        }
    }
}
