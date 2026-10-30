import ImpKit
import SwiftUI

/// Where to look: a head turn (−1…1 each axis, y down) toward a point. Saturates ~220 pt away,
/// like the Mac's. The Mac measures from the bottom of the screen and turns its y over; UIKit's y
/// already grows downward, so a point above the Imp is negative here (a look up).
enum Gaze {
    static func toward(_ p: CGPoint, from c: CGPoint) -> CGPoint {
        let dx = p.x - c.x, dy = p.y - c.y
        let d = max(1, hypot(dx, dy))
        let k = min(1, d / 220)
        return CGPoint(x: dx / d * k, y: dy / d * k)
    }
}

/// One Imp, drawn by the Mac's own renderer. The caller supplies the frame's `date` (the stage's
/// timeline), so a screenful of figures shares one display link.
struct ImpFigure: View {
    var imp: LinkImp
    var mood: Mood = .idle
    var performance: Performance?
    /// Extra tilt in degrees (swinging in the hand).
    var lean = 0.0
    var gaze: CGPoint?
    var attentive = false
    var hopSince: Double?
    var date: Date
    @State private var puppet = Puppet()

    var body: some View {
        let beat = performance?.beat(at: date)
        let clock = BodyClock(imp.id)
        var cue = Puppet.Cue(mood: beat?.step.mood ?? mood, step: beat?.step, hue: imp.hue, gaze: gaze,
                             attentive: attentive, lean: lean, hopSince: beat?.hopSince ?? hopSince,
                             stepElapsed: beat?.elapsed, traits: imp.traits)
        cue.breathing = true
        let (face, motion) = puppet.frame(cue, at: clock.time(date))
        return Canvas { ctx, size in
            ImpRenderer.draw(&ctx, size: size, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                             glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
        }
    }
}

/// A self-driven Imp for places outside the stage (chat header, onboarding).
struct LiveImp: View {
    var imp: LinkImp
    var mood: Mood = .idle
    var performance: Performance?
    var gaze: CGPoint?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            ImpFigure(imp: imp, mood: mood, performance: performance, gaze: gaze, date: timeline.date)
        }
    }
}

extension Mood {
    /// A mood the Mac named (`LinkUpdate.mood`); nil for one this build doesn't know.
    init?(link name: String) { self.init(rawValue: name) }
}

extension LinkImp {
    /// The stand-in shown on the pairing screen.
    static let greeter = LinkImp(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "Imp",
                                 hue: 0, scale: 1, traits: .plain)
}
