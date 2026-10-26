import ImpKit
import SwiftUI

/// A speckled egg: where new Imps come from. Idle it breathes and gives a tiny wobble now and then.
/// Given a `hatchStart` it cracks open: the wobble builds, a zig-zag crack runs round the shell, the
/// cap pops off and the lower half splits and falls away, with a few shards and sparkles. The new
/// Imp should appear at `revealAt` (seconds after the start); the pieces keep flying until `hatchDuration`.
struct ImpEgg: View {
    /// Total length of the hatch effect, in seconds.
    static let hatchDuration: TimeInterval = 1.5
    /// When (seconds after the start) the shell has opened and the new Imp should appear.
    static let revealAt: TimeInterval = 0.76
    /// The moment the cap pops off.
    private static let pop = 0.68
    /// Room the canvas reaches past the egg's frame on every side, so flying pieces aren't cut off.
    static let room: CGFloat = 48

    var hatchStart: Date?
    /// Review renders: draw the hatch at this fixed time instead of following the clock.
    private var fixed: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(hatchStart: Date? = nil) { self.hatchStart = hatchStart }

    /// A still frame, `elapsed` seconds into the hatch (nil = idle at rest).
    init(elapsed: Double?) { self.fixed = elapsed }

    var body: some View {
        if let fixed {
            Canvas { ctx, size in Self.draw(&ctx, size: size, hatch: fixed, idle: 0, reduceMotion: reduceMotion) }
                .padding(-Self.room)
        } else {
            let hatching = hatchStart.map { Date.now.timeIntervalSince($0) < Self.hatchDuration + 0.1 } ?? false
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion && !hatching)) { timeline in
                let hatch = hatchStart.map { timeline.date.timeIntervalSince($0) }
                Canvas { ctx, size in
                    Self.draw(&ctx, size: size, hatch: hatch, idle: timeline.date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion)
                }
                .padding(-Self.room)
            }
        }
    }

    // MARK: Drawing

    private static func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }
    private static func easeOut(_ x: Double) -> Double { let c = min(max(x, 0), 1); return 1 - (1 - c) * (1 - c) }
    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// `size` is the canvas, `room` larger than the egg's frame on every side.
    static func draw(_ ctx: inout GraphicsContext, size canvas: CGSize, hatch: Double?, idle: Double, reduceMotion: Bool) {
        let size = CGSize(width: canvas.width - 2 * room, height: canvas.height - 2 * room)
        let w = size.width * 0.62, h = size.height * 0.8
        let r = CGRect(x: room + (size.width - w) / 2, y: room + size.height - h - 4, width: w, height: h)
        let foot = CGPoint(x: r.midX, y: r.maxY)

        guard let e = hatch, e >= 0 else {
            // Idle: breathing, and every few seconds a small wobble.
            var c = ctx
            var tilt = 0.0, breath = 0.0
            if !reduceMotion {
                breath = 0.012 * sin(idle * 1.6)
                let cycle = idle.truncatingRemainder(dividingBy: 5.3)
                if cycle < 0.7 { tilt = 3.2 * sin(cycle * 24) * (1 - cycle / 0.7) }
            }
            c.translateBy(x: foot.x, y: foot.y)
            c.rotate(by: .degrees(tilt))
            c.scaleBy(x: 1 - breath * 0.5, y: 1 + breath)
            c.translateBy(x: -foot.x, y: -foot.y)
            shell(&c, r)
            return
        }

        if reduceMotion {
            // Just a quick fade, no flying pieces.
            var c = ctx
            c.opacity = 1 - ease(e / (revealAt + 0.2))
            shell(&c, r)
            return
        }

        let seam = seamPoints(r)
        let u = clamp((e - pop) / (hatchDuration - pop))

        if e < pop {
            // Wobble that builds up, cracks spreading across the shell.
            let k = clamp(e / pop)
            let amp = 10 * pow(ease(k), 1.4)
            let phase = 2 * .pi * (4.5 * e + 6 * e * e / pop)
            var c = ctx
            c.translateBy(x: foot.x, y: foot.y)
            c.rotate(by: .degrees(amp * sin(phase)))
            c.scaleBy(x: 1 + 0.02 * k, y: 1 - 0.02 * k)
            c.translateBy(x: -foot.x, y: -foot.y)
            shell(&c, r)
            cracks(&c, r, seam: seam, progress: easeOut((e - 0.18) / (pop - 0.2)))
            return
        }

        // A warm flash from inside as it opens.
        let flash = 1 - ease(u / 0.55)
        if flash > 0 {
            let centre = CGPoint(x: r.midX, y: seam[seam.count / 2].y + h * 0.1)
            SoftLight.glow(&ctx, at: centre, radius: w * 0.95, color: Dungeon.flame, opacity: 0.55 * flash, squash: 0.9)
        }

        let capRegion = polygon(seam + [CGPoint(x: r.maxX + 4, y: r.minY - 40), CGPoint(x: r.minX - 4, y: r.minY - 40)])
        let lowRegion = polygon(seam + [CGPoint(x: r.maxX + 4, y: r.maxY + 40), CGPoint(x: r.minX - 4, y: r.maxY + 40)])
        let mid = seam[seam.count / 2].y
        // A zigzag down the middle: it starts on the centre line, then steps left and right.
        let jag: [CGPoint] = (0...5).map { i in
            let side: Double = i % 2 == 0 ? -1 : 1
            let x: Double = i == 0 ? r.midX : r.midX + side * w * 0.035
            let y: Double = mid + (r.maxY + 20 - mid) * Double(i) / 5
            return CGPoint(x: x, y: y)
        }
        let leftRegion = polygon([CGPoint(x: r.minX - 40, y: mid - 30)] + jag + [CGPoint(x: r.minX - 40, y: r.maxY + 40)])
        let rightRegion = polygon([CGPoint(x: r.maxX + 40, y: mid - 30)] + jag + [CGPoint(x: r.maxX + 40, y: r.maxY + 40)])

        // The lower halves swing apart and drop away.
        let fall = ease(u / 0.9)
        for side in [-1.0, 1.0] {
            ctx.drawLayer { l in
                l.opacity = 1 - ease((u - 0.25) / 0.65)
                let pivot = CGPoint(x: r.midX + side * w * 0.25, y: r.maxY - h * 0.2)
                l.translateBy(x: side * w * 0.3 * easeOut(u / 0.8), y: h * 0.08 * fall * fall)
                l.translateBy(x: pivot.x, y: pivot.y)
                l.rotate(by: .degrees(side * 24 * fall * fall))
                l.translateBy(x: -pivot.x, y: -pivot.y)
                l.clip(to: lowRegion)
                l.clip(to: side < 0 ? leftRegion : rightRegion)
                shell(&l, r)
            }
        }
        // The cap pops up, tumbling and fading.
        ctx.drawLayer { l in
            l.opacity = 1 - ease((u - 0.3) / 0.7)
            let pivot = CGPoint(x: r.midX, y: r.minY + h * 0.2)
            l.translateBy(x: w * 0.22 * easeOut(u), y: -h * 0.4 * easeOut(u / 0.85) + h * 0.05 * u * u)
            l.translateBy(x: pivot.x, y: pivot.y)
            l.rotate(by: .degrees(32 * easeOut(u / 0.9)))
            l.translateBy(x: -pivot.x, y: -pivot.y)
            l.clip(to: capRegion)
            shell(&l, r)
        }
        sparkles(&ctx, r, origin: CGPoint(x: r.midX, y: mid), u: u)
    }

    /// The jagged line the shell splits along (left to right, across the egg's upper middle).
    private static func seamPoints(_ r: CGRect) -> [CGPoint] {
        let n = 8
        let base = r.minY + r.height * 0.42
        return (0...n).map { i in
            let f = Double(i) / Double(n)
            let zig = i == 0 || i == n ? 0 : (i % 2 == 0 ? -1.0 : 1.0) * r.height * (0.045 + 0.03 * DungeonBackdrop.noise(i, 41))
            return CGPoint(x: r.minX - 4 + (r.width + 8) * f, y: base + zig)
        }
    }

    private static func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    /// Cracks spreading out from the middle of the seam: the seam itself, plus a few side branches.
    private static func cracks(_ ctx: inout GraphicsContext, _ r: CGRect, seam: [CGPoint], progress: Double) {
        guard progress > 0 else { return }
        let mid = seam.count / 2
        var paths: [(Path, Double)] = []
        // Seam, growing both ways from the centre.
        let right = Path { $0.addLines(Array(seam[mid...])) }
        let left = Path { $0.addLines(Array(seam[...mid].reversed())) }
        paths += [(right, 0), (left, 0)]
        // Branches (down and up from points on the seam), starting a little later.
        let branches: [(Int, [(Double, Double)], Double)] = [
            (mid - 1, [(-0.03, 0.09), (0.03, 0.17), (-0.02, 0.26)], 0.35),
            (mid + 1, [(0.04, 0.08), (-0.02, 0.15), (0.03, 0.22)], 0.5),
            (mid + 2, [(0.0, -0.08), (0.04, -0.15), (0.0, -0.22)], 0.55),
            (mid - 2, [(-0.04, -0.07), (0.01, -0.14)], 0.65)
        ]
        for (i, pts, start) in branches {
            let s = seam[i]
            paths.append((Path { p in
                p.move(to: s)
                for (dx, dy) in pts { p.addLine(to: CGPoint(x: s.x + dx * r.width * 2, y: s.y + dy * r.height)) }
            }, start))
        }
        ctx.drawLayer { l in
            l.clip(to: egg(r))
            for (path, start) in paths {
                let p = clamp((progress - start) / (1 - start))
                guard p > 0 else { continue }
                let part = path.trimmedPath(from: 0, to: p)
                l.stroke(part, with: .color(Color(red: 0.36, green: 0.2, blue: 0.2).opacity(0.85)),
                         style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                l.stroke(part.offsetBy(dx: 1.2, dy: 1.2), with: .color(.white.opacity(0.5)),
                         style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Little cream shards and golden sparkles bursting out of the seam.
    private static func sparkles(_ ctx: inout GraphicsContext, _ r: CGRect, origin: CGPoint, u: Double) {
        for i in 0..<12 {
            let n = { DungeonBackdrop.noise(i, $0) }
            let angle = -Double.pi * (0.08 + 0.84 * n(51))                        // mostly upward
            let speed = r.height * (0.55 + 0.6 * n(53))
            let life = 0.55 + 0.4 * n(57)
            let t = u * 0.82
            let fade = 1 - ease(u / life)
            guard fade > 0 else { continue }
            let pos = CGPoint(x: origin.x + cos(angle) * speed * easeOut(t / 0.8) * 0.9 + (n(59) - 0.5) * r.width * 0.4,
                              y: origin.y + sin(angle) * speed * easeOut(t / 0.8) * 0.9 + r.height * 0.55 * t * t)
            let s = 3 + 5 * n(61)
            var c = ctx
            c.opacity = fade
            c.translateBy(x: pos.x, y: pos.y)
            if i % 3 == 0 {
                // A four-point sparkle.
                var star = Path()
                for k in 0..<8 {
                    let a = Double(k) * .pi / 4, rad = k % 2 == 0 ? s * 1.1 : s * 0.3
                    let pt = CGPoint(x: cos(a) * rad, y: sin(a) * rad)
                    k == 0 ? star.move(to: pt) : star.addLine(to: pt)
                }
                star.closeSubpath()
                c.rotate(by: .degrees(u * 90))
                c.fill(star, with: .color(Dungeon.flame))
            } else {
                // A shard of shell.
                c.rotate(by: .degrees(n(63) * 360 + u * 300 * (n(65) - 0.5)))
                var shard = Path()
                shard.move(to: CGPoint(x: -s, y: s * 0.5))
                shard.addLine(to: CGPoint(x: 0, y: -s * 0.8))
                shard.addLine(to: CGPoint(x: s, y: s * 0.4))
                shard.closeSubpath()
                c.fill(shard, with: .color(i % 2 == 0 ? Dungeon.cream : Color(red: 0.95, green: 0.82, blue: 0.74)))
            }
        }
    }

    /// The whole shell: cream gradient, speckles and a glossy highlight.
    private static func shell(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let w = r.width, h = r.height
        ctx.fill(egg(r), with: .linearGradient(Gradient(colors: [Dungeon.cream, Color(red: 0.95, green: 0.82, blue: 0.74)]),
                                               startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
        for i in 0..<9 {
            let x = r.minX + w * (0.2 + 0.6 * DungeonBackdrop.noise(i, 11)), y = r.minY + h * (0.25 + 0.6 * DungeonBackdrop.noise(i, 13))
            let s = 4 + 6 * DungeonBackdrop.noise(i, 17)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s * 0.8)),
                     with: .color(Color.imp(DungeonBackdrop.noise(i, 19)).opacity(0.55)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: r.minX + w * 0.22, y: r.minY + h * 0.14, width: w * 0.16, height: h * 0.2)),
                 with: .color(.white.opacity(0.55)))
    }

    static func egg(_ r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.62), control1: CGPoint(x: r.midX + r.width * 0.42, y: r.minY),
                   control2: CGPoint(x: r.maxX, y: r.minY + r.height * 0.32))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.minY + r.height * 0.88),
                   control2: CGPoint(x: r.midX + r.width * 0.3, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.62), control1: CGPoint(x: r.midX - r.width * 0.3, y: r.maxY),
                   control2: CGPoint(x: r.minX, y: r.minY + r.height * 0.88))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + r.height * 0.32),
                   control2: CGPoint(x: r.midX - r.width * 0.42, y: r.minY))
        return p
    }
}
