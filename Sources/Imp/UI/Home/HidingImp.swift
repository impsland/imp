import AppKit
import ImpKit
import SwiftUI

/// An Imp that's out but hidden (the menu bar's Hide), as it shows on its pedestal: under a
/// bedsheet like a little ghost. It floats a little, its horns tent the cloth, the hem flutters,
/// a hint of its colour glows underneath, and its eyes peek out through two holes, following the
/// cursor and blinking. So the window explains why it isn't on the desktop.
struct HidingImp: View {
    let hue: Double
    /// Its own rhythm (the same as its desktop self's), so a hidden troupe doesn't bob in unison.
    var clock = BodyClock.shared
    /// Its centre on screen, to peek at the cursor. Nil = look ahead.
    var center: () -> CGPoint? = { nil }
    /// Neighbours at the side don't need every frame.
    var still = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { timeline in
            let t = clock.time(timeline.date)
            Canvas { ctx, size in
                let look = center().map { Gaze.toward(NSEvent.mouseLocation, from: $0) } ?? CGPoint(x: 0, y: 0.1)
                Self.draw(&ctx, size: size, hue: hue, t: still ? 0 : t, look: look)
            }
        }
    }

    /// The ghost, drawn in a square the size of the Imp's own canvas (head base at 84% height).
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, hue: Double, t: Double, look: CGPoint) {
        let w = size.width, h = size.height
        let lift = (sin(t * 1.7) * 0.5 + 0.5) * h * 0.05            // 0…5% of its height
        let floor = h * 0.86

        // Its shadow on the stone: smaller and fainter as it rises.
        let shadowScale = 1 - lift / (h * 0.05) * 0.25
        let shadow = CGRect(x: w / 2 - w * 0.3 * shadowScale, y: floor - h * 0.03, width: w * 0.6 * shadowScale, height: h * 0.06)
        ctx.fill(Ellipse().path(in: shadow), with: .color(.black.opacity(0.32 - 0.1 * (1 - shadowScale) * 4)))

        var g = ctx
        g.translateBy(x: w / 2, y: floor - lift)
        g.rotate(by: .degrees(sin(t * 1.1) * 2.5))
        g.translateBy(x: -w / 2, y: -(floor - lift))
        g.translateBy(x: 0, y: -lift)

        // A hint of the Imp itself, glowing under the hem.
        let glow = CGRect(x: w * 0.24, y: floor - h * 0.16, width: w * 0.52, height: h * 0.18)
        g.fill(Ellipse().path(in: glow), with: .radialGradient(
            Gradient(colors: [Color.imp(hue).opacity(0.85), Color.imp(hue).opacity(0)]),
            center: CGPoint(x: glow.midX, y: glow.midY), startRadius: 0, endRadius: glow.width / 2))

        let sheet = GhostSheet(phase: t * 2.4).path(in: CGRect(x: w * 0.1, y: h * 0.06, width: w * 0.8, height: floor - h * 0.06 - h * 0.02))
        g.drawLayer { l in
            l.addFilter(.shadow(color: .black.opacity(0.35), radius: 6, y: 3))
            l.fill(sheet, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.95), Color(red: 0.93, green: 0.88, blue: 0.86)]),
                startPoint: CGPoint(x: w * 0.3, y: h * 0.1), endPoint: CGPoint(x: w * 0.7, y: floor)))
        }
        // Soft folds in the cloth, and a warm rim of torchlight down one side.
        g.drawLayer { l in
            l.clip(to: sheet)
            for (x, bend) in [(0.36, -0.03), (0.52, 0.02), (0.66, 0.035)] {
                var fold = Path()
                fold.move(to: CGPoint(x: w * x, y: h * 0.48))
                fold.addQuadCurve(to: CGPoint(x: w * (x + bend * 2), y: floor),
                                  control: CGPoint(x: w * (x + bend + sin(t * 2.4 + x * 9) * 0.01), y: h * 0.7))
                l.stroke(fold, with: .color(Color(red: 0.55, green: 0.42, blue: 0.45).opacity(0.22)), lineWidth: 1.4)
            }
            l.fill(Rectangle().path(in: CGRect(x: w * 0.8, y: 0, width: w * 0.2, height: h)),
                   with: .linearGradient(Gradient(colors: [Dungeon.ember.opacity(0), Dungeon.ember.opacity(0.18)]),
                                         startPoint: CGPoint(x: w * 0.8, y: 0), endPoint: CGPoint(x: w * 0.92, y: 0)))
        }

        // Two eye holes cut in the cloth, with its white eyes peeking out (and blinking).
        let blink = Self.blink(t)
        for side in [-1.0, 1.0] {
            let hole = CGRect(x: w / 2 + side * w * 0.115 - w * 0.07, y: h * 0.36, width: w * 0.14, height: h * 0.17)
            g.fill(Ellipse().path(in: hole), with: .color(Dungeon.deep))
            let eyeH = hole.height * 0.62 * blink
            let eye = CGRect(x: hole.midX - hole.width * 0.28 + look.x * hole.width * 0.16,
                             y: hole.midY - eyeH / 2 - look.y * hole.height * 0.14,
                             width: hole.width * 0.56, height: max(0.8, eyeH))
            g.fill(Ellipse().path(in: eye), with: .color(.white.opacity(0.95)))
        }
    }

    /// 1 = open, dipping to closed for a quick blink every few seconds.
    private static func blink(_ t: Double) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        guard cycle < 0.16 else { return 1 }
        return max(0.08, abs(cycle - 0.08) / 0.08)
    }
}

/// The bedsheet: a round top with two little peaks where the horns poke at it, sides that flare
/// out as the cloth falls, and a scalloped hem that ripples with `phase`.
struct GhostSheet: Shape {
    var phase: Double

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + w * x, y: r.minY + h * y) }
        var path = Path()
        let hemY = 0.94
        path.move(to: p(0.02, hemY))
        // Left side, up to the left horn: a short, slightly pointed peak (its little curled horn
        // tenting the cloth), leaning out a touch like the real one.
        path.addCurve(to: p(0.17, 0.30), control1: p(0.07, 0.72), control2: p(0.1, 0.44))
        path.addQuadCurve(to: p(0.215, 0.05), control: p(0.165, 0.15))
        path.addQuadCurve(to: p(0.31, 0.13), control: p(0.25, 0.085))
        // Over the crown.
        path.addCurve(to: p(0.69, 0.13), control1: p(0.4, 0.01), control2: p(0.6, 0.01))
        path.addQuadCurve(to: p(0.785, 0.05), control: p(0.75, 0.085))
        path.addQuadCurve(to: p(0.83, 0.30), control: p(0.835, 0.15))
        // Right side, down to the hem.
        path.addCurve(to: p(0.98, hemY), control1: p(0.9, 0.44), control2: p(0.93, 0.72))
        // The hem: scallops, rippling.
        let scallops = 5
        for i in 0..<scallops {
            let x0 = 0.98 - 0.96 * Double(i) / Double(scallops)
            let x1 = 0.98 - 0.96 * Double(i + 1) / Double(scallops)
            let dip = 0.06 + 0.025 * sin(phase + Double(i) * 1.3)
            path.addQuadCurve(to: p(x1, hemY + 0.01 * sin(phase * 0.7 + Double(i))), control: p((x0 + x1) / 2, hemY + dip))
        }
        path.closeSubpath()
        return path
    }
}
