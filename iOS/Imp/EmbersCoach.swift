import SwiftUI

/// The first round of Embers teaches itself: a line of embers to fling an Imp through, the rules on
/// a small card, then a countdown. These are the pieces drawn for it.

/// What to do, at the top of the screen.
struct CoachCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(Dungeon.cream)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.black.opacity(0.3), in: Capsule())
    }
}

/// A ghost finger that presses the Imp and flicks it through the embers, again and again. Decorative:
/// the caption says it all. With Reduce Motion it is a still arrow along the line.
struct CoachFinger: View {
    var guide: GameRound.Guide
    var date: Date
    var reduceMotion: Bool
    /// The real finger has the Imp.
    var hidden: Bool

    private static let cycle = 3.0
    private static let dots = StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [0.1, 9])

    var body: some View {
        Canvas { ctx, _ in
            if reduceMotion { still(&ctx) } else { moving(&ctx) }
        }
        .opacity(hidden ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: hidden)
        .accessibilityHidden(true)
    }

    private var control: CGPoint {
        let a = guide.from, b = guide.to
        let dx = b.x - a.x, dy = b.y - a.y
        return CGPoint(x: (a.x + b.x) / 2 - dy * 0.16, y: (a.y + b.y) / 2 + dx * 0.16)
    }

    private func point(_ t: Double) -> CGPoint {
        let a = guide.from, c = control, b = guide.to, u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private func trail(to t: Double) -> Path {
        var path = Path()
        path.move(to: point(0))
        let steps = max(2, Int(t * 28))
        for i in 1...steps { path.addLine(to: point(t * Double(i) / Double(steps))) }
        return path
    }

    private func moving(_ ctx: inout GraphicsContext) {
        let u = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
        // Press, drag along the line (slow, then a flick), let go.
        let travel = min(1, max(0, (u - 0.4) / 1.0))
        let t = pow(travel, 1.7)
        let appear = min(1, u / 0.3)
        let release = u > 1.4 ? max(0, 1 - (u - 1.4) / 0.4) : 1
        let alpha = appear * release
        guard alpha > 0 else { return }
        if t > 0.01 { ctx.stroke(trail(to: t), with: .color(.white.opacity(0.6 * alpha)), style: Self.dots) }
        let p = point(t)
        let pressed = u < 0.4 ? 1 - 0.18 * min(1, u / 0.25) : 0.82
        SoftLight.glow(&ctx, at: p, radius: 50, color: .white, opacity: 0.3 * alpha)
        SparkArt.dot(&ctx, p, 19 * pressed, .white.opacity(0.5 * alpha))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48)),
                   with: .color(.white.opacity(0.75 * alpha)), lineWidth: 2)
    }

    private func still(_ ctx: inout GraphicsContext) {
        ctx.stroke(trail(to: 1), with: .color(.white.opacity(0.6)), style: Self.dots)
        let tip = guide.to, before = point(0.96)
        let angle = atan2(tip.y - before.y, tip.x - before.x)
        var head = Path()
        for side in [-0.55, 0.55] {
            head.move(to: tip)
            head.addLine(to: CGPoint(x: tip.x - 16 * cos(angle + side), y: tip.y - 16 * sin(angle + side)))
        }
        ctx.stroke(head, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        SparkArt.dot(&ctx, guide.from, 19, .white.opacity(0.4))
    }
}

/// The rules, for a few seconds or until a tap.
struct RulesCard: View {
    var bonk: Bool
    var date: Date
    var reduceMotion: Bool
    var play: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                row(.ember, "Catch embers. More in one flight, more points.")
                row(.kindling, "Kindling gives you more time.")
                row(.smoke, "Steer clear of smoke.")
                if bonk { row(.bonk, "Bonk Imps together for a bonus.") }
            }
            Button("Play", action: play).buttonStyle(EmberButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(Dungeon.deep.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .onTapGesture(perform: play)
    }

    private func row(_ icon: RuleIcon.Kind, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            // Drawn on a canvas big enough for the whole glow (the kindling's reaches ~33 pt), which
            // keeps a 34 pt place in the row: the light fades out on its own instead of at a box's edge.
            RuleIcon(kind: icon, t: reduceMotion ? 0 : date.timeIntervalSinceReferenceDate)
                .frame(width: RuleIcon.canvas, height: RuleIcon.canvas)
                .frame(width: 34, height: 34)
                .allowsHitTesting(false)
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.cream)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tiny live drawing of what a row is about.
private struct RuleIcon: View {
    enum Kind { case ember, kindling, smoke, bonk }
    /// Room for the widest glow, all the way to where it fades to nothing.
    static let canvas: CGFloat = 80
    var kind: Kind
    var t: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            switch kind {
            case .ember:
                SparkArt.ember(&ctx, at: c, radius: 5.5, fade: 1, pulse: 0.88 + 0.12 * sin(t * 7))
            case .kindling:
                SparkArt.kindling(&ctx, at: c, radius: 6, fade: 1, pulse: 0.9 + 0.1 * sin(t * 3.2))
            case .smoke:
                SparkArt.smoke(&ctx, at: c, radius: 17, fade: 1, t: t)
            case .bonk:
                let gap = 4 + 6 * (0.5 + 0.5 * sin(t * 4))
                SparkArt.dot(&ctx, CGPoint(x: c.x - 5 - gap, y: c.y), 6, Dungeon.ember)
                SparkArt.dot(&ctx, CGPoint(x: c.x + 5 + gap, y: c.y), 6, Dungeon.ember)
                SoftLight.glow(&ctx, at: c, radius: 12, color: Dungeon.flame, opacity: 0.9 * (1 - gap / 10))
            }
        }
    }
}

/// 3, 2, 1: big and soft.
struct CoachCountdown: View {
    var number: Int
    var reduceMotion: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 110, weight: .bold, design: .rounded))
            .foregroundStyle(Dungeon.flame)
            .shadow(color: Dungeon.ember.opacity(0.7), radius: 24)
            .id(number)
            .transition(reduceMotion ? .opacity : .scale(scale: 1.5).combined(with: .opacity))
            .animation(.easeOut(duration: 0.5), value: number)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A quiet text button.
struct CoachSkipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded, weight: .semibold))
            .foregroundStyle(Dungeon.muted)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
