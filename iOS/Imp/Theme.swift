import ImpKit
import SwiftUI

/// The phone's look: the same cosy, warm dungeon as the Mac's home window.
enum Dungeon {
    static let deep = Color(red: 0.12, green: 0.06, blue: 0.11)
    static let wallTop = Color(red: 0.17, green: 0.08, blue: 0.15)
    static let wallBottom = Color(red: 0.29, green: 0.10, blue: 0.13)
    static let ember = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let flame = Color(red: 1.0, green: 0.80, blue: 0.36)
    static let cream = Color(red: 1.0, green: 0.95, blue: 0.88)
    static let muted = Color(red: 1.0, green: 0.95, blue: 0.88).opacity(0.6)
    static let card = Color.white.opacity(0.07)
    static let cardEdge = Color.white.opacity(0.1)
    static let good = Color(red: 0.45, green: 0.85, blue: 0.55)

    static var wall: LinearGradient {
        LinearGradient(colors: [wallTop, wallBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// The wall with a few embers floating up, like the Mac's stage.
struct DungeonBackdrop: View {
    var quiet = false

    var body: some View {
        ZStack {
            Dungeon.wall
            Canvas { ctx, size in Self.bricks(&ctx, size: size) }
            if !quiet {
                TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
                    Canvas { ctx, size in Self.embers(&ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate) }
                }
            }
            // A soft floor so the room has a bottom.
            LinearGradient(colors: [.clear, .black.opacity(0.32)], startPoint: .init(x: 0.5, y: 0.65), endPoint: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    static func bricks(_ ctx: inout GraphicsContext, size: CGSize) {
        let bw: CGFloat = 64, bh: CGFloat = 28
        var row = 0
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = row % 2 == 0 ? 0 : -bw / 2
            while x < size.width {
                let r = CGRect(x: x + 2, y: y + 2, width: bw - 4, height: bh - 4)
                ctx.fill(Path(roundedRect: r, cornerRadius: 7), with: .color(.white.opacity(0.045 * (0.6 + 0.4 * noise(row, Int(x))))))
                x += bw
            }
            y += bh
            row += 1
        }
    }

    /// Embers drifting up; one in a while is a heart.
    static func embers(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<9 {
            let period = 11.0 + Double(i % 4) * 2.5
            let phase = (t / period + noise(i, 11)).truncatingRemainder(dividingBy: 1)
            let x = size.width * (0.08 + 0.84 * noise(i, 3)) + sin(t * 0.7 + Double(i)) * 14
            let y = size.height * (1.05 - phase * 1.15)
            let fade = sin(phase * .pi)
            let r = 1.6 + 2.2 * noise(i, 7)
            SoftLight.glow(&ctx, at: CGPoint(x: x, y: y), radius: r * 5, color: Dungeon.ember, opacity: 0.22 * fade)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(Dungeon.flame.opacity(0.7 * fade)))
        }
    }

    /// A stable pseudo-random 0…1 from two integers.
    static func noise(_ a: Int, _ b: Int) -> Double {
        var h = UInt64(truncatingIfNeeded: a) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(truncatingIfNeeded: b) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 29; h = h &* 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
        return Double(h % 10_000) / 10_000
    }
}

/// A rounded card on the wall.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .background(Dungeon.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }
}

extension View {
    func card(radius: CGFloat = 18) -> some View { modifier(CardBackground(radius: radius)) }
}

/// The primary, warm button.
struct EmberButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(filled ? Dungeon.deep : Dungeon.cream)
            .padding(.horizontal, 22).padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background {
                if filled {
                    Capsule().fill(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Dungeon.ember.opacity(0.4), radius: 12, y: 4)
                } else {
                    Capsule().fill(Dungeon.card).overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
