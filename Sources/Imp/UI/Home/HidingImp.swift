import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// An Imp that's out but hidden (the menu bar's Hide), as it shows on its pedestal: under a
/// bedsheet like a little ghost. It floats a little, its horns tent the cloth, the hem flutters,
/// a hint of its colour glows underneath, and its eyes peek out through two holes, following the
/// cursor and blinking. So the window explains why it isn't on the desktop.
struct HidingImp: View {
    let hue: Double
    /// Its character: its horns tent the sheet, so a droopy Imp and a perky one differ under it.
    var traits = ImpTraits.plain
    /// Its own rhythm (the same as its desktop self's), so a hidden troupe doesn't bob in unison.
    var clock = BodyClock.shared
    /// Its centre on screen, to peek at the cursor. Nil = look ahead.
    var center: () -> CGPoint? = { nil }
    /// Neighbours at the side don't need every frame.
    var still = false
    @Environment(\.stageAwake) private var awake

    var body: some View {
        let tents = HornTents(traits: traits)
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still || !awake)) { timeline in
            let t = clock.time(timeline.date)
            Canvas { ctx, size in
                let look = center().map { Gaze.toward(NSEvent.mouseLocation, from: $0) } ?? CGPoint(x: 0, y: 0.1)
                Self.draw(&ctx, size: size, hue: hue, tents: tents, t: still ? 0 : t, look: look)
            }
        }
    }

    /// The ghost, drawn in a square the size of the Imp's own canvas (head base at 84% height).
    static func draw(_ ctx: inout GraphicsContext, size: CGSize, hue: Double, tents: HornTents = HornTents(), t: Double, look: CGPoint) {
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

        let sheet = GhostSheet(phase: t * 2.4, tents: tents).path(in: CGRect(x: w * 0.1, y: h * 0.06, width: w * 0.8, height: floor - h * 0.06 - h * 0.02))
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

/// Where an Imp's two horns stand, in its 100-unit design space, from the real horn geometry
/// (so the sheet that drapes over them follows the Imp's own outline).
struct HornTents: Equatable {
    /// One horn: the outer foot, the tip and the inner foot.
    struct Tent: Equatable { var outer: CGPoint, tip: CGPoint, inner: CGPoint }
    var left: Tent, right: Tent
    /// The top of the head, where the sheet crosses between the horns.
    var crown: Double

    init(traits: ImpTraits = .plain) {
        var face = Face.settled(.idle)
        Puppet.apply(traits, to: &face)
        let s = ImpRenderer.size
        let base = s.base * face.headH, top = s.top * face.headH
        let head = Head(cx: s.cx, cy: s.bottom - base, rx: s.rx * face.headW, top: top, bottom: base,
                        square: face.square, sag: face.sag, peak: face.peak, wobble: 0, lean: face.lookX, t: 0)
        let pose = Pose(face)
        func tent(_ side: Double) -> Tent {
            let horn = Horn(side: side, head: head, pose: pose, face: face, wiggle: 0)
            let box = horn.front.boundingRect.union(horn.back.boundingRect)
            let outerX = side < 0 ? box.minX : box.maxX, innerX = side < 0 ? box.maxX : box.minX
            return Tent(outer: CGPoint(x: outerX, y: horn.base.y + horn.baseR * 0.4),
                        tip: horn.tip,
                        inner: CGPoint(x: innerX, y: min(horn.base.y - horn.baseR * 0.6, head.cy - head.top * 0.8)))
        }
        left = tent(-1)
        right = tent(1)
        crown = head.cy - head.top
    }
}

/// The bedsheet: it drapes over the head and tents over each horn where the real horn stands
/// (`tents`), sides that flare out as the cloth falls, and a scalloped hem that ripples with `phase`.
/// The tents are in the Imp's 100-unit space, and the sheet's rect is the part of the canvas it fills.
struct GhostSheet: Shape {
    var phase: Double
    var tents = HornTents()
    /// The canvas the sheet is laid on, as fractions (the rect the path is asked for sits inside it).
    var canvas = CGRect(x: 0.1, y: 0.06, width: 0.8, height: 0.78)

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        // Design units (0…100 of the whole canvas) to this rect.
        func d(_ q: CGPoint) -> CGPoint {
            CGPoint(x: r.minX + w * (q.x / 100 - canvas.minX) / canvas.width,
                    y: r.minY + h * (q.y / 100 - canvas.minY) / canvas.height)
        }
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + w * x, y: r.minY + h * y) }
        var path = Path()
        let hemY = 0.94
        let lt = tents.left, rt = tents.right
        // The cloth rides a little outside the horn so it reads as cloth over a horn.
        let lo = d(lt.outer), lp = d(CGPoint(x: lt.tip.x, y: lt.tip.y - 3.5)), li = d(lt.inner)
        let ro = d(rt.outer), rp = d(CGPoint(x: rt.tip.x, y: rt.tip.y - 3.5)), ri = d(rt.inner)
        let crownY = d(CGPoint(x: 50, y: tents.crown - 3)).y
        path.move(to: p(0.02, hemY))
        // Left side, up the outer edge of the left horn and over its tip.
        path.addCurve(to: CGPoint(x: lo.x - w * 0.015, y: lo.y), control1: p(0.07, 0.72), control2: CGPoint(x: lo.x - w * 0.05, y: lo.y + h * 0.2))
        path.addQuadCurve(to: lp, control: CGPoint(x: lo.x - w * 0.01, y: (lo.y + lp.y) / 2 - h * 0.02))
        path.addQuadCurve(to: li, control: CGPoint(x: (lp.x + li.x) / 2 + (li.x - lp.x) * 0.25, y: lp.y - h * 0.01))
        // Over the crown.
        path.addCurve(to: ri, control1: CGPoint(x: li.x + (ri.x - li.x) * 0.25, y: crownY - h * 0.1),
                      control2: CGPoint(x: li.x + (ri.x - li.x) * 0.75, y: crownY - h * 0.1))
        path.addQuadCurve(to: rp, control: CGPoint(x: (rp.x + ri.x) / 2 + (ri.x - rp.x) * 0.25, y: rp.y - h * 0.01))
        path.addQuadCurve(to: CGPoint(x: ro.x + w * 0.015, y: ro.y), control: CGPoint(x: ro.x + w * 0.01, y: (ro.y + rp.y) / 2 - h * 0.02))
        // Right side, down to the hem.
        path.addCurve(to: p(0.98, hemY), control1: CGPoint(x: ro.x + w * 0.05, y: ro.y + h * 0.2), control2: p(0.93, 0.72))
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
