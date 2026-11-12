import AppKit
import ImpKit
import SwiftUI

/// The Imp in the doorway: alive, breathing, watching the cursor, in its colour. It can act out
/// any animation (`performance`), like its desktop self.
struct StageImp: View {
    let hue: Double
    var mood: Mood = .idle
    var performance: Performance?
    /// Its character (see `ImpTraits`).
    var traits = ImpTraits.plain
    /// Its own rhythm (the same as its desktop self's).
    var clock = BodyClock.shared
    /// Its centre on screen (the cursor is in screen coordinates). Nil = just look ahead.
    var center: () -> CGPoint? = { nil }
    @State private var puppet = Puppet()
    @State private var watch = StageWatch()
    @Environment(\.stageAwake) private var awake
    @Environment(\.stageStill) private var still
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(StageSchedule(paused: !awake || still != nil || reduceMotion, fast: Energy.shared.frame,
                                   slow: Energy.shared.calmFrame, watch: watch)) { timeline in
            let date = still ?? timeline.date
            let beat = performance?.beat(at: date)
            let cue = Puppet.Cue(mood: beat?.step.mood ?? mood, step: beat?.step, hue: hue,
                                 gaze: still != nil ? nil : center().map { Gaze.toward(NSEvent.mouseLocation, from: $0) },
                                 hopSince: beat?.hopSince, stepElapsed: beat?.elapsed, traits: traits)
            let (face, motion) = puppet.frame(cue, at: clock.time(date))
            let _ = watch.note(moving: !puppet.isSettled || beat != nil, at: date)
            Canvas { ctx, size in
                ImpRenderer.draw(&ctx, size: size, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                                 glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
            }
        }
    }
}

/// Remembers whether this Imp moved lately, so the timeline draws at the full rate while its head turns
/// (to the cursor, through a beat) and at the calm rate while it only breathes. A reference: the schedule
/// reads what the last frame found (main thread only).
final class StageWatch: @unchecked Sendable {
    private(set) var moving = false
    private var hold = LivelyHold()
    private var mouse = NSEvent.mouseLocation

    /// Ends a frame. The cursor moving counts as movement, so the first frame after it is already fast.
    func note(moving settling: Bool, at date: Date) {
        let p = NSEvent.mouseLocation
        let cursor = hypot(p.x - mouse.x, p.y - mouse.y) > 0.5
        mouse = p
        moving = hold.lively(moving: settling || cursor, at: date)
    }
}

/// Frames for an Imp in the window: `fast` (60 fps) while `watch` says it moves, `slow` (30) while it
/// breathes, none while paused.
struct StageSchedule: TimelineSchedule {
    var paused: Bool
    var fast: Double
    var slow: Double
    var watch: StageWatch

    func entries(from start: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(date: start, paused: paused, fast: fast, slow: slow, watch: watch)
    }

    struct Entries: Sequence, IteratorProtocol {
        var date: Date
        let paused: Bool
        let fast: Double
        let slow: Double
        let watch: StageWatch

        mutating func next() -> Date? {
            guard !paused else { return nil }
            date = date.addingTimeInterval(watch.moving ? fast : slow)
            return date
        }
    }
}
