import SwiftUI

/// Little symbols Imp can pop above its head during antics.
enum Glyph: Equatable {
    case notes, question, exclaim, idea
    /// A bead of sweat: nervous, scared, embarrassed.
    case sweat
    /// A heart: affection.
    case heart
    /// Sparkles: proud, starry-eyed.
    case sparkles
    /// Busy with a tool (spinning gear).
    case gear
}

/// Decorations around the head: "!" ticks, sparkles, a heart, z's and antic glyphs,
/// in the Imp's own colour.
struct Extras {
    let accent: Color

    func draw(_ ctx: inout GraphicsContext, head: Head, face f: Face, t: Double) {
        if f.burst > 0.03 { burst(&ctx, head: head, amount: f.burst, t: t) }
        if f.sparkle > 0.03 { sparkles(&ctx, head: head, amount: f.sparkle, t: t) }
        if f.heart > 0.03 { heart(&ctx, head: head, amount: f.heart, t: t) }
        if f.sleep > 0.3 { zs(&ctx, head: head, amount: f.sleep, t: t) }
        if f.spiral > 0.05 { orbit(&ctx, head: head, amount: f.spiral, t: t) }
    }

    /// Cartoon stars circling over a dizzy head. The far ones pass behind and fade.
    private func orbit(_ ctx: inout GraphicsContext, head: Head, amount: Double, t: Double) {
        for k in 0..<3 {
            let a = t * 4 + Double(k) * 2 * .pi / 3
            let depth = (sin(a) + 1) / 2                   // 1 = nearest
            var c = ctx
            c.opacity = amount * (0.45 + 0.55 * depth)
            let p = CGPoint(x: head.cx + cos(a) * head.rx * 0.75, y: head.cy - head.top * 1.12 + sin(a) * 3.5)
            c.fill(star(at: p, r: 2.2 + depth * 1.4), with: .color(Color(red: 1, green: 0.78, blue: 0.2)))
        }
    }

    private func burst(_ ctx: inout GraphicsContext, head: Head, amount: Double, t: Double) {
        let pulse = 0.85 + 0.15 * sin(t * 9)
        var c = ctx
        c.opacity = min(1, amount)
        for side in [-1.0, 1.0] {
            for (k, ang) in [1.0, 1.3, 1.6].enumerated() {
                let o = head.point(-Double.pi / 2 + side * ang)
                let dx = o.x - head.cx, dy = o.y - head.cy
                let len = max(1, hypot(dx, dy))
                let start = 4.5 + Double(k % 2) * 1.2
                let l = (k == 1 ? 3.6 : 2.6) * pulse * amount
                var p = Path()
                p.move(to: CGPoint(x: o.x + dx / len * start, y: o.y + dy / len * start))
                p.addLine(to: CGPoint(x: o.x + dx / len * (start + l), y: o.y + dy / len * (start + l)))
                c.stroke(p, with: .color(accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
    }

    private func sparkles(_ ctx: inout GraphicsContext, head: Head, amount: Double, t: Double) {
        for (x, y, r, ph) in [(0.95, -1.0, 3.4, 0.0), (1.15, -0.65, 2.0, 1.7), (0.78, -1.25, 1.6, 3.1)] {
            let tw = 0.55 + 0.45 * sin(t * 5 + ph)
            var c = ctx
            c.opacity = amount * tw
            let p = CGPoint(x: head.cx + head.rx * x, y: head.cy + head.top * y)
            c.fill(star(at: p, r: r * (0.8 + 0.2 * tw)), with: .color(accent))
        }
    }

    private func star(at c: CGPoint, r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
        return p
    }

    private func heart(_ ctx: inout GraphicsContext, head: Head, amount: Double, t: Double) {
        let phase = (t * 0.6).truncatingRemainder(dividingBy: 1)
        let x = head.cx + head.rx * 0.95 + sin(phase * 6) * 1.5
        let y = head.cy - head.top * 1.0 - phase * 8
        let r = 2.6
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + r * 1.1))
        p.addCurve(to: CGPoint(x: x - r * 1.2, y: y - r * 0.3), control1: CGPoint(x: x - r * 0.4, y: y + r * 0.6), control2: CGPoint(x: x - r * 1.2, y: y + r * 0.3))
        p.addArc(center: CGPoint(x: x - r * 0.6, y: y - r * 0.35), radius: r * 0.6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: x + r * 0.6, y: y - r * 0.35), radius: r * 0.6, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: x, y: y + r * 1.1), control1: CGPoint(x: x + r * 1.2, y: y + r * 0.3), control2: CGPoint(x: x + r * 0.4, y: y + r * 0.6))
        var c = ctx
        c.opacity = amount * (1 - phase * 0.6)
        c.fill(p, with: .color(accent))
    }

    private func zs(_ ctx: inout GraphicsContext, head: Head, amount: Double, t: Double) {
        for k in 0..<3 {
            let phase = (t * 0.35 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let text = Text("z").font(.system(size: 6 + phase * 6, weight: .heavy, design: .rounded))
                .foregroundStyle(accent.opacity(0.75))
            var c = ctx
            c.opacity = sin(phase * .pi) * (amount - 0.3) / 0.7
            c.draw(text, at: CGPoint(x: head.cx + head.rx * 0.8 + phase * 12 + sin(phase * 7) * 2,
                                     y: head.cy - head.top * 0.5 - phase * 26))
        }
    }

    /// Pops a symbol above Imp's head (♪ while humming, ?, !, 💡) with a small overshoot.
    /// `fade` (1 → 0) lets a glyph leave gently instead of vanishing when its step ends.
    func draw(_ ctx: inout GraphicsContext, glyph: Glyph, head: Head, age: Double, t: Double, fade: Double = 1) {
        let pop = min(1, age * 5) * (1 + 0.25 * sin(min(1, age * 3) * .pi) * exp(-age * 3))
        var ctx = ctx
        ctx.opacity *= max(0, min(1, fade))
        func symbol(_ name: String, _ color: Color, at p: CGPoint, size: Double, opacity: Double = 1, angle: Double = 0) {
            var img = ctx.resolve(Image(systemName: name))
            img.shading = .color(color)
            var c = ctx
            c.opacity = opacity
            c.translateBy(x: p.x, y: p.y)
            c.rotate(by: .radians(angle))
            let s = size * pop
            c.draw(img, in: CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
        }
        let anchor = CGPoint(x: head.cx + head.rx * 0.95, y: head.cy - head.top * 1.1 + sin(t * 3) * 1.2)
        switch glyph {
        case .notes:
            for k in 0..<3 {
                let phase = (age * 0.55 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                symbol(k % 2 == 0 ? "music.note" : "music.quarternote.3", accent,
                       at: CGPoint(x: head.cx + head.rx * (0.7 + phase * 0.4) + sin(phase * 6) * 2.5,
                                   y: head.cy - head.top * (0.6 + phase * 0.9)),
                       size: 8 + phase * 3, opacity: sin(phase * .pi))
            }
        case .question: symbol("questionmark", accent, at: anchor, size: 11)
        case .exclaim: symbol("exclamationmark", accent, at: anchor, size: 11)
        case .idea: symbol("lightbulb.fill", Color(red: 1, green: 0.78, blue: 0.2), at: anchor, size: 12)
        case .gear: symbol("gearshape.fill", accent, at: anchor, size: 12, angle: t * 2.4)
        case .heart: symbol("heart.fill", accent, at: anchor, size: 11)
        case .sparkles: symbol("sparkles", Color(red: 1, green: 0.82, blue: 0.3), at: anchor, size: 12)
        case .sweat:
            // Slides slowly down beside the brow, on the side away from the other glyphs.
            let slide = min(1, age * 0.6)
            symbol("drop.fill", Color(red: 0.55, green: 0.8, blue: 1), at: CGPoint(x: head.cx - head.rx * 0.95,
                   y: head.cy - head.top * (0.75 - 0.25 * slide)), size: 8)
        }
    }
}
