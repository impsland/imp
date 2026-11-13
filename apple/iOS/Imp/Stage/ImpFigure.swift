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
    /// Room to draw around its square, as fractions of its size: a tilted head's glyph and a made
    /// animation's tilts and stretches reach out of it (`ImpBoundsTests` measures how far).
    var bleed = EdgeInsets()
    @State private var puppet = Puppet()

    var body: some View {
        let beat = performance?.beat(at: date)
        let clock = BodyClock(imp.id)
        var cue = Puppet.Cue(mood: beat?.step.mood ?? mood, step: beat?.step, hue: imp.hue, gaze: gaze,
                             attentive: attentive, lean: lean, hopSince: beat?.hopSince ?? hopSince,
                             stepElapsed: beat?.elapsed, traits: imp.traits)
        cue.breathing = true
        let (face, motion) = puppet.frame(cue, at: clock.time(date))
        let bleed = bleed
        return Bleed(fraction: bleed) {
            Canvas { ctx, size in
                let inner = CGSize(width: size.width / (1 + bleed.leading + bleed.trailing), height: size.height / (1 + bleed.top + bleed.bottom))
                ctx.translateBy(x: inner.width * bleed.leading, y: inner.height * bleed.top)
                ImpRenderer.draw(&ctx, size: inner, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                                 glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
            }
        }
    }

    /// What the stage gives an Imp: the worst a made animation can do (a full tilt with a glyph, a hop,
    /// a stretch, perky horns) reaches this far past its square, most of all above it and to the right.
    static let stageBleed = EdgeInsets(top: 0.45, leading: 0.3, bottom: 0.1, trailing: 0.45)
}

/// Lays its content out as big as offered and `fraction` of that more on each side: the content draws
/// past the frame without the frame (layout, touches, position) changing.
private struct Bleed: Layout {
    var fraction: EdgeInsets

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = ProposedViewSize(width: bounds.width * (1 + fraction.leading + fraction.trailing),
                                    height: bounds.height * (1 + fraction.top + fraction.bottom))
        let origin = CGPoint(x: bounds.minX - bounds.width * fraction.leading, y: bounds.minY - bounds.height * fraction.top)
        for view in subviews { view.place(at: origin, anchor: .topLeading, proposal: size) }
    }
}

/// A self-driven Imp for places outside the stage (chat header, onboarding). It breathes at the calm
/// rate and only speeds up while its mood changes; it stops when it is covered or the app is away.
struct LiveImp: View {
    var imp: LinkImp
    var mood: Mood = .idle
    var performance: Performance?
    var gaze: CGPoint?
    /// All ears, horns perked (watching something it cares about).
    var attentive = false
    @State private var pacer = StagePacer()
    @State private var activity = FramePolicy.Activity.lively

    var body: some View {
        PacedTimeline(activity: activity) { date in
            let _ = frame(date)
            ImpFigure(imp: imp, mood: mood, performance: performance, gaze: gaze, attentive: attentive, date: date)
        }
        .onAppear { pacer.onChange = { activity = $0 } }
    }

    private func frame(_ date: Date) {
        pacer.note(mood: mood, of: imp.id, awake: mood != .sleepy, at: date)
        let acting = performance.map { date.timeIntervalSince($0.started) < $0.duration } ?? false
        pacer.settle(moving: acting, empty: false, at: date)
    }
}

extension Mood {
    /// A mood the Mac named (`LinkUpdate.mood`); nil for one this build doesn't know.
    init?(link name: String) { self.init(rawValue: name) }
}

extension LinkImp {
    /// The stand-in shown on the first screen.
    static let greeter = LinkImp(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, name: "Imp",
                                 hue: 0, scale: 1, traits: .plain)
}

/// The soft light around an Imp, in the Imp's own colour. One radial gradient the render server
/// draws once: it has no redraw closure and no blur, so a stage of Imps pays nothing for it per
/// frame. It is a decoration, so it is gone when the policy says the phone should save (`\.decorated`).
struct Halo: View, Equatable {
    var color: Color
    var opacity: Double
    @Environment(\.decorated) private var decorated

    nonisolated static func == (a: Halo, b: Halo) -> Bool { a.color == b.color && a.opacity == b.opacity }

    var body: some View {
        if decorated {
            Rectangle()
                .fill(EllipticalGradient(gradient: SoftLight.falloff(color, opacity), center: .center,
                                         startRadiusFraction: 0, endRadiusFraction: 0.5))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
