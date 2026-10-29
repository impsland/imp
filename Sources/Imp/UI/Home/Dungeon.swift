import ImpKit
import SwiftUI

/// The look of the Imps' home: a cosy little dungeon, warm and friendly rather than scary.
enum Dungeon {
    static let deep = Color(red: 0.12, green: 0.06, blue: 0.11)
    static let wallTop = Color(red: 0.17, green: 0.08, blue: 0.15)
    static let wallBottom = Color(red: 0.29, green: 0.10, blue: 0.13)
    static let stone = Color(red: 0.42, green: 0.25, blue: 0.33)
    static let stoneLight = Color(red: 0.55, green: 0.34, blue: 0.41)
    static let doorway = Color(red: 0.07, green: 0.03, blue: 0.07)
    static let ember = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let flame = Color(red: 1.0, green: 0.80, blue: 0.36)
    static let cream = Color(red: 1.0, green: 0.95, blue: 0.88)
    static let muted = Color(red: 1.0, green: 0.95, blue: 0.88).opacity(0.6)
    /// Cards and wells sitting on the wall.
    static let card = Color.white.opacity(0.055)
    static let cardEdge = Color.white.opacity(0.09)

    static var wall: LinearGradient {
        LinearGradient(colors: [wallTop, wallBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension EnvironmentValues {
    /// False while the home window can't be seen: its animations pause.
    @Entry var stageAwake = true
}

/// The wall with a few embers floating up (one in a while is a heart). `quiet` draws just the
/// wall, for settings screens.
struct DungeonBackdrop: View {
    var quiet = false
    @Environment(\.stageAwake) private var awake

    var body: some View {
        ZStack {
            Dungeon.wall
            Canvas { ctx, size in Self.bricks(&ctx, size: size, opacity: quiet ? 0.03 : 0.045) }
            if !quiet {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !awake)) { timeline in
                    Canvas { ctx, size in Self.embers(&ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate) }
                }
            }
            // A soft floor so the room has a bottom.
            LinearGradient(colors: [.clear, .black.opacity(quiet ? 0.18 : 0.3)], startPoint: .init(x: 0.5, y: 0.7), endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Drawing

    static func bricks(_ ctx: inout GraphicsContext, size: CGSize, opacity: Double) {
        let bw: CGFloat = 64, bh: CGFloat = 28
        var row = 0
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = row % 2 == 0 ? 0 : -bw / 2
            while x < size.width {
                let r = CGRect(x: x + 2, y: y + 2, width: bw - 4, height: bh - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(.white.opacity(opacity * (0.6 + 0.4 * noise(row, Int(x))))))
                x += bw
            }
            y += bh
            row += 1
        }
    }

    /// A round-topped doorway of chunky, friendly stones.
    static func arch(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let radius = r.width / 2
        var opening = Path()
        opening.move(to: CGPoint(x: r.minX, y: r.maxY))
        opening.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        opening.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        opening.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        opening.closeSubpath()
        ctx.fill(opening, with: .linearGradient(Gradient(colors: [Dungeon.doorway, Dungeon.doorway.opacity(0.75)]),
                                                startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        // Warm light spilling from inside, behind wherever the Imp stands.
        SoftLight.glow(&ctx, at: CGPoint(x: r.midX, y: r.maxY - r.height * 0.2), radius: r.width * 0.5,
                       color: Dungeon.ember, opacity: 0.2, squash: 0.62)

        // Stones around the curve…
        let stones = 11, thick: CGFloat = 26
        let c = CGPoint(x: r.midX, y: r.minY + radius)
        for i in 0..<stones {
            let a0 = Double.pi + Double(i) / Double(stones) * .pi, a1 = Double.pi + Double(i + 1) / Double(stones) * .pi
            var p = Path()
            p.addArc(center: c, radius: radius + 2, startAngle: .radians(a0 + 0.012), endAngle: .radians(a1 - 0.012), clockwise: false)
            p.addArc(center: c, radius: radius + thick, startAngle: .radians(a1 - 0.01), endAngle: .radians(a0 + 0.01), clockwise: true)
            p.closeSubpath()
            let shade = i == stones / 2 ? Dungeon.stoneLight : Dungeon.stone.opacity(0.85 + 0.15 * noise(i, 3))
            ctx.fill(p, with: .color(shade))
        }
        // …and down both sides.
        for side in [-1.0, 1.0] {
            var y = r.minY + radius + 3
            var i = 0
            while y < r.maxY - 4 {
                let h = min(30, r.maxY - y)
                let x = side < 0 ? r.minX - thick - 1 : r.maxX + 1
                let stone = CGRect(x: x + (i % 2 == 0 ? 0 : side * 4), y: y, width: thick, height: h - 3)
                ctx.fill(Path(roundedRect: stone, cornerRadius: 6), with: .color(Dungeon.stone.opacity(0.8 + 0.2 * noise(i, Int(side * 7)))))
                y += h
                i += 1
            }
        }
    }

    static func torch(_ ctx: inout GraphicsContext, at p: CGPoint, t: Double) {
        let flicker = 1 + 0.08 * sin(t * 9.3) + 0.05 * sin(t * 15.1 + 1)
        // Glow: a wide warm halo and a brighter core around the flame (see `Doorway.glowRoom`).
        SoftLight.glow(&ctx, at: CGPoint(x: p.x, y: p.y - 14), radius: Doorway.glowRoom, color: Dungeon.ember, opacity: 0.2 * flicker)
        SoftLight.glow(&ctx, at: CGPoint(x: p.x, y: p.y - 16), radius: 30, color: Dungeon.flame, opacity: 0.16 * flicker)
        // Holder.
        ctx.fill(Path(roundedRect: CGRect(x: p.x - 4, y: p.y, width: 8, height: 30), cornerRadius: 3),
                 with: .color(Color(red: 0.45, green: 0.27, blue: 0.18)))
        ctx.fill(Path(roundedRect: CGRect(x: p.x - 9, y: p.y - 3, width: 18, height: 7), cornerRadius: 3),
                 with: .color(Color(red: 0.55, green: 0.36, blue: 0.24)))
        // Flame: a soft teardrop that sways a little.
        let h = 26 * flicker, w: CGFloat = 15
        let sway = 2.2 * sin(t * 4.1)
        var f = Path()
        let base = CGPoint(x: p.x, y: p.y - 2)
        f.move(to: CGPoint(x: base.x + sway, y: base.y - h))
        f.addQuadCurve(to: CGPoint(x: base.x + w / 2, y: base.y - 6), control: CGPoint(x: base.x + w / 2 + 1, y: base.y - h * 0.55))
        f.addQuadCurve(to: CGPoint(x: base.x - w / 2, y: base.y - 6), control: CGPoint(x: base.x, y: base.y + 3))
        f.addQuadCurve(to: CGPoint(x: base.x + sway, y: base.y - h), control: CGPoint(x: base.x - w / 2 - 1, y: base.y - h * 0.55))
        ctx.fill(f, with: .linearGradient(Gradient(colors: [Dungeon.flame, Dungeon.ember]),
                                          startPoint: CGPoint(x: base.x, y: base.y - h), endPoint: base))
        ctx.fill(Path(ellipseIn: CGRect(x: base.x - 3.5, y: base.y - 13, width: 7, height: 9)), with: .color(.white.opacity(0.7)))
    }

    static func embers(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<16 {
            let speed = 14 + 10 * noise(i, 1)
            let period = Double(size.height + 40) / speed
            let phase = (t + noise(i, 2) * period).truncatingRemainder(dividingBy: period) / period
            let y = size.height + 20 - phase * (size.height + 40)
            let x = noise(i, 3) * size.width + 14 * sin(t * 0.7 + Double(i))
            let fade = sin(phase * .pi)
            let heart = i % 7 == 3
            let s: CGFloat = heart ? 7 : 2 + 2 * noise(i, 4)
            let color = (heart ? Color(red: 1, green: 0.45, blue: 0.55) : Dungeon.ember).opacity(0.55 * fade)
            if heart {
                ctx.fill(heartPath(CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)), with: .color(color))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)), with: .color(color))
            }
        }
    }

    static func heartPath(_ r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.3), control1: CGPoint(x: r.midX - r.width * 0.1, y: r.maxY - r.height * 0.2),
                   control2: CGPoint(x: r.minX, y: r.midY))
        p.addArc(center: CGPoint(x: r.minX + r.width / 4, y: r.minY + r.height * 0.3), radius: r.width / 4, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: r.maxX - r.width / 4, y: r.minY + r.height * 0.3), radius: r.width / 4, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.midY),
                   control2: CGPoint(x: r.midX + r.width * 0.1, y: r.maxY - r.height * 0.2))
        return p
    }

    /// Cheap, stable pseudo-randomness in 0…1.
    static func noise(_ a: Int, _ b: Int) -> Double {
        let v = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }
}

/// A round-topped doorway with a torch on each side: the Imp stands in it.
struct Doorway: View {
    static let torchRoom: CGFloat = 70
    /// How far a torch's light reaches. The canvas extends this far past the view's frame, so the
    /// light fades out on its own instead of being cut off at the frame's edge.
    static let glowRoom: CGFloat = 92
    @Environment(\.stageAwake) private var awake

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !awake)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvas in
                let room = Self.glowRoom
                ctx.translateBy(x: room, y: room)
                let size = CGSize(width: canvas.width - 2 * room, height: canvas.height - 2 * room)
                let door = CGRect(x: Self.torchRoom, y: 0, width: size.width - 2 * Self.torchRoom, height: size.height)
                    .insetBy(dx: 26, dy: 0).offsetBy(dx: 0, dy: 26)
                DungeonBackdrop.arch(&ctx, CGRect(x: door.minX, y: door.minY, width: door.width, height: door.height - 26))
                for side in [-1.0, 1.0] {
                    let x = side < 0 ? Self.torchRoom / 2 + 6 : size.width - Self.torchRoom / 2 - 6
                    DungeonBackdrop.torch(&ctx, at: CGPoint(x: x, y: size.height * 0.42), t: t + side * 1.7)
                }
            }
            .padding(-Self.glowRoom)
        }
        .allowsHitTesting(false)
    }
}

/// The little stone the Imp stands on, glowing in its colour.
struct Pedestal: View {
    var hue: Double
    var lit = true
    /// Height of the stone's top surface above the view's bottom edge.
    static let surface: CGFloat = 18

    var body: some View {
        ZStack {
            Ellipse().fill(LinearGradient(colors: [Dungeon.stoneLight, Dungeon.stone], startPoint: .top, endPoint: .bottom))
                .frame(height: 30)
                .offset(y: 6)
            Ellipse().fill(Color(red: 0.62, green: 0.42, blue: 0.48))
                .frame(height: 22)
            Ellipse().strokeBorder(.white.opacity(0.12), lineWidth: 1).frame(height: 22)
        }
        .frame(height: 36)
        .background {
            // Its colour glowing up from the stone: wider than the stone and fading out on its own
            // (a background, so it doesn't make the stone any bigger).
            SoftGlow(color: Color.imp(hue), opacity: lit ? 0.5 : 0.16)
                .frame(width: 250, height: 84)
                .offset(y: -8)
        }
    }
}
