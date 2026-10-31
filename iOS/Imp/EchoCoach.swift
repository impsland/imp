import SwiftUI

/// The first round of Echo teaches itself: the Imps light two runes, the player taps them back, then
/// a small card with the rules and a countdown. These are the pieces drawn for it.

/// What to do, at the top of the screen, for the guided step.
enum EchoLesson {
    static func caption(watching: Bool, slipped: Bool) -> String {
        if slipped { return String(localized: "Not quite. Watch again") }
        return watching ? String(localized: "Watch the Imps light the runes") : String(localized: "Now you: tap them in the same order")
    }
}

/// A pulsing ring and a tapping finger over the rune to tap next. Decorative: the caption says it
/// all. With Reduce Motion it is a still ring and finger.
struct EchoTapHint: View {
    var center: CGPoint
    var color: Color
    var date: Date
    var reduceMotion: Bool

    var body: some View {
        Canvas { ctx, _ in
            let t = reduceMotion ? 0.4 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            let r = 54 + 18 * t
            ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color.opacity(reduceMotion ? 0.8 : 0.9 * (1 - t))), lineWidth: 3)
            // The finger comes down on the stone, then lifts.
            let press = reduceMotion ? 0 : max(0, sin(t * .pi * 2))
            let finger = ctx.resolve(Image(systemName: "hand.point.up.left.fill"))
            var shaded = finger
            shaded.shading = .color(.white.opacity(0.9))
            ctx.draw(shaded, in: CGRect(x: center.x + 6 - 4 * press, y: center.y + 4 + 6 * press, width: 34, height: 36))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The rules of Echo, for a few seconds or until a tap.
struct EchoRulesCard: View {
    var play: () -> Void

    var body: some View {
        CardFit {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    row("eye.fill", "Watch the Imps light the runes.")
                    row("hand.tap.fill", "Tap them back in the same order. Each round adds one.")
                    row("heart.fill", "Three slips and it's over. A clean round pays double.")
                }
                Button("Play", action: play).buttonStyle(EmberButtonStyle())
            }
        }
        .gameCard()
        .onTapGesture(perform: play)
    }

    private func row(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(EchoArt.accent)
                .frame(width: 34, height: 34)
                .background(EchoArt.accent.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.cream)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
