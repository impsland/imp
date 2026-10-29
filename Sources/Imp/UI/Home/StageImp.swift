import AppKit
import ImpKit
import SwiftUI

/// The Imp in the doorway: alive, breathing, watching the cursor, in its colour. It can act out
/// any animation (`performance`), like its desktop self.
struct StageImp: View {
    let hue: Double
    var mood: Mood = .idle
    var performance: Performance?
    /// Its own rhythm (the same as its desktop self's).
    var clock = BodyClock.shared
    /// Its centre on screen (the cursor is in screen coordinates). Nil = just look ahead.
    var center: () -> CGPoint? = { nil }
    @State private var puppet = Puppet()
    @Environment(\.stageAwake) private var awake

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !awake)) { timeline in
            let date = timeline.date
            let beat = performance?.beat(at: date)
            let cue = Puppet.Cue(mood: beat?.step.mood ?? mood, step: beat?.step, hue: hue,
                                 gaze: center().map { Gaze.toward(NSEvent.mouseLocation, from: $0) },
                                 hopSince: beat?.hopSince)
            let (face, motion) = puppet.frame(cue, at: clock.time(date))
            Canvas { ctx, size in
                ImpRenderer.draw(&ctx, size: size, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                                 glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
            }
        }
    }
}
