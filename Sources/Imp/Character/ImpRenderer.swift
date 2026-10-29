import SwiftUI

/// Pure drawing of Imp in a 100×100 design space.
enum ImpRenderer {
    static let eyeWhite = Color(red: 1.0, green: 0.99, blue: 0.98)

    /// Base proportions: a dome a bit wider than tall, widest just below the middle.
    static let size = (cx: 50.0, bottom: 84.0, rx: 33.0, top: 33.0, base: 19.0)

    static func draw(_ ctx: inout GraphicsContext, size canvas: CGSize, face f: Face, motion m: Motion,
                     shadow: Bool = true, glyph: Glyph? = nil, glyphAge: Double = 0, glyphFade: Double = 1) {
        let s = min(canvas.width, canvas.height) / 100
        ctx.translateBy(x: (canvas.width - 100 * s) / 2, y: (canvas.height - 100 * s) / 2)
        ctx.scaleBy(x: s, y: s)

        let rx = size.rx * f.headW
        let top = size.top * f.headH, base = size.base * f.headH
        let palette = Palette(hue: f.hue)
        let head = Head(cx: size.cx, cy: size.bottom - base, rx: rx, top: top, bottom: base,
                        square: f.square, sag: f.sag, peak: f.peak, wobble: f.wobble + m.ripple, lean: f.lookX, t: m.t)
        let pose = Pose(f)
        let horns = [Horn(side: -1, head: head, pose: pose, face: f, wiggle: m.hornL),
                     Horn(side: 1, head: head, pose: pose, face: f, wiggle: m.hornR)]
        // Squash, tilt and shake around the base, so Imp stays planted.
        func body(lift: Double) -> CGAffineTransform {
            CGAffineTransform(translationX: size.cx + m.shakeX, y: size.bottom + m.bob - lift)
                .rotated(by: (f.tilt + m.tilt) * .pi / 180)
                .scaledBy(x: 1 + m.squash, y: 1 - m.squash)
                .translatedBy(x: -size.cx, y: -size.bottom)
        }
        let lift = m.lift > 0 ? headroom(for: m.lift, head: head, horns: horns, at: body(lift: 0)) : 0
        if shadow { drawShadow(&ctx, width: rx * (0.85 + f.sag * 0.08), lift: max(0, lift - m.bob)) }
        ctx.concatenate(body(lift: lift))

        for h in horns { h.draw(in: &ctx, head: head, front: false, palette: palette) }
        drawSkin(&ctx, head: head, f: f, pose: pose, palette: palette)
        drawEyes(&ctx, head: head, f: f, m: m, pose: pose)
        for h in horns { h.draw(in: &ctx, head: head, front: true, palette: palette) }
        let extras = Extras(accent: palette.accent)
        extras.draw(&ctx, head: head, face: f, t: m.t)
        if let glyph { extras.draw(&ctx, glyph: glyph, head: head, age: glyphAge, t: m.t, fade: glyphFade) }
    }

    /// How high a hop may lift the body: all of `lift`, unless that would carry the top of the head
    /// or a horn out of the frame (tall, startled poses). Then the whole hop is lower, in
    /// proportion, so it still rises and falls smoothly instead of flattening against the edge.
    private static func headroom(for lift: Double, head: Head, horns: [Horn], at transform: CGAffineTransform) -> Double {
        var top = head.path.applying(transform).boundingRect.minY
        for h in horns {
            for p in [h.front, h.back] where !p.isEmpty { top = min(top, p.applying(transform).boundingRect.minY) }
        }
        let room = max(0, top - headMargin)
        return lift * min(1, room / Motion.hopHeight)
    }

    /// Space kept free above the highest point of a hop (design units).
    static let headMargin = 1.5

    /// A soft contact shadow on the floor: a wide, faint pool and a tighter, darker core, both
    /// fading out completely (lifting off the ground fades it a little).
    private static func drawShadow(_ ctx: inout GraphicsContext, width w: Double, lift: Double) {
        let c = CGPoint(x: size.cx, y: size.bottom + 1.5)
        let k = max(0.4, 1 - lift * 0.08)
        SoftLight.glow(&ctx, at: c, radius: w + 4, color: .black, opacity: 0.13 * k, squash: 0.17)
        SoftLight.glow(&ctx, at: c, radius: w * 0.62, color: .black, opacity: 0.12 * k, squash: 0.2)
    }

    private static func drawSkin(_ ctx: inout GraphicsContext, head: Head, f: Face, pose: Pose, palette p: Palette) {
        let path = head.path
        let g = Gradient(colors: [p.skinTop.mix(p.flushTop, f.flush).color,
                                  p.skin.mix(p.skin.mix(p.flushBottom, 0.6), f.flush).color,
                                  p.skinBottom.mix(p.flushBottom, f.flush).color])
        ctx.fill(path, with: .linearGradient(g, startPoint: CGPoint(x: head.cx, y: head.cy - head.top),
                                             endPoint: CGPoint(x: head.cx, y: head.cy + head.bottom)))
        var inside = ctx
        inside.clip(to: path)
        // Matte volume: soft light on the upper dome that follows the turn…
        let lc = head.project(pose.rotate(.onBall(lon: -0.35, lat: -0.5)))
        inside.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(0.14), .white.opacity(0.05), .clear]),
                                                center: lc, startRadius: 0, endRadius: head.rx * 0.8))
        // …and a little occlusion where the mochi meets the table.
        inside.fill(path, with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.07)]),
                                                startPoint: CGPoint(x: head.cx, y: head.cy + head.bottom * 0.35),
                                                endPoint: CGPoint(x: head.cx, y: head.cy + head.bottom)))
        guard f.blush > 0.03 else { return }
        for side in [-1.0, 1.0] {
            let n = pose.rotate(.onBall(lon: side * 0.7, lat: 0.45))
            guard n.z > 0.1 else { continue }
            let c = head.project(n)
            inside.opacity = f.blush * 0.85 * min(1, n.z * 2)
            for k in 0..<3 {
                let x = c.x + Double(k - 1) * 2.1, y = c.y + (k == 1 ? -0.8 : 0)
                inside.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                            with: .color(p.blush))
            }
        }
    }

    private static func drawEyes(_ ctx: inout GraphicsContext, head: Head, f: Face, m: Motion, pose: Pose) {
        let open = max(0, 1 - m.blink * 0.93)
        // ^ ^ eyes don't cross-fade with open eyes: the ovals grow out of them, like eyes
        // opening after a happy squint (that cross-fade read as a glitch when a hum ended).
        let arc = max(0, min(1, f.arc))
        let opening = 1 - arc
        let filled = max(0, 1 - max(f.squeeze, f.spiral))
        var clipped = ctx
        clipped.clip(to: head.path)     // eyes live on the face, never past its edge
        let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        for side in [-1.0, 1.0] {
            let n = pose.rotate(.onBall(lon: side * 0.46, lat: 0.12))
            guard n.z > 0.02 else { continue }
            let center = head.project(n)
            let squint = side < 0 ? f.squint : 0
            let rx = 6.6 * f.eyeW * head.rx / size.rx
            let ry = 9.0 * f.eyeH

            // Foreshorten like a decal on a ball: squash along the on-screen normal by n.z.
            var e = clipped
            e.opacity = min(1, (n.z - 0.02) / 0.3)
            e.translateBy(x: center.x, y: center.y)
            let phi = atan2(n.y, n.x)
            e.rotate(by: .radians(phi))
            e.scaleBy(x: max(0.2, n.z), y: 1)
            e.rotate(by: .radians(-phi))

            if filled > 0.01 && opening > 0.04 {
                var fe = e
                fe.opacity *= filled
                let h = ry * open * (1 - squint * 0.3) * opening
                let lid = min(0.92, f.lid + squint * 0.3)
                if lid > 0.01 {
                    let keep = Path(CGRect(x: -30, y: 0, width: 60, height: 40))
                        .applying(CGAffineTransform(rotationAngle: -side * f.slant * 0.6))
                        .applying(CGAffineTransform(translationX: 0, y: -h + 2 * h * lid))
                    fe.clip(to: keep)
                }
                fe.fill(Path(ellipseIn: CGRect(x: -rx, y: -h, width: 2 * rx, height: 2 * h)), with: .color(eyeWhite))
            }
            if f.arc > 0.01 {
                var p = Path()
                let w = rx * 1.05, y0 = f.bend * ry * 0.25
                p.move(to: CGPoint(x: -w, y: y0))
                p.addQuadCurve(to: CGPoint(x: w, y: y0), control: CGPoint(x: 0, y: y0 - f.bend * ry * 1.05))
                var ae = e
                ae.opacity *= max(0, min(1, (arc - 0.3) / 0.45)) * (1 - f.squeeze)
                ae.stroke(p, with: .color(eyeWhite), style: stroke)
            }
            if f.spiral > 0.01 {
                // A little spiral per eye, spinning in opposite directions.
                var p = Path()
                let turns = 2.3, n = 48, spin = m.t * 7 * side
                for i in 0...n {
                    let k = Double(i) / Double(n), a = k * turns * 2 * .pi + spin
                    let pt = CGPoint(x: cos(a) * rx * 1.2 * k, y: sin(a) * ry * 0.95 * k)
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                var de = e
                de.opacity *= f.spiral
                de.stroke(p, with: .color(eyeWhite), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
            if f.squeeze > 0.01 {
                var p = Path()
                let w = rx * 0.95, h = ry * 0.5
                p.move(to: CGPoint(x: side * w, y: -h))
                p.addLine(to: CGPoint(x: -side * w, y: 0))
                p.addLine(to: CGPoint(x: side * w, y: h))
                var se = e
                se.opacity *= f.squeeze
                se.stroke(p, with: .color(eyeWhite), style: stroke)
            }
        }
    }
}
