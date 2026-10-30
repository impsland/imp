import SwiftUI

/// Embers on the stage: the way in (a small flame when the Imps are asleep), the sparks, the score
/// and the end card. Drawn inside the stage's own timeline, so it reads the engine each frame.
struct GameLayer: View {
    let engine: StageEngine
    let date: Date
    let size: CGSize
    let insets: EdgeInsets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = engine.reduceMotion = reduceMotion
        let offer = engine.round == nil && !engine.order.isEmpty && !engine.isConnected()
        ZStack {
            if let round = engine.round {
                Sparks(round: round, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                if round.isOver {
                    EndCard(score: round.score, best: engine.best, again: { engine.startGame() }, done: { engine.endGame() })
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    Scoreboard(score: round.score, progress: round.progress)
                        .position(x: size.width / 2, y: insets.top + 66)
                        .allowsHitTesting(false)
                }
            }
            if offer {
                Button { engine.startGame() } label: {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Dungeon.flame)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.3), in: Circle())
                        .overlay(Circle().strokeBorder(Dungeon.cardEdge))
                        .shadow(color: Dungeon.ember.opacity(0.35), radius: 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play Embers")
                .position(x: size.width - 40, y: size.height - insets.bottom - 36)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: offer)
        .animation(.spring(duration: 0.4), value: engine.round?.isOver)
    }
}

/// The score, with a thin ring running down the round.
private struct Scoreboard: View {
    var score: Int
    var progress: Double

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Dungeon.cardEdge, lineWidth: 2.5)
                Circle().trim(from: 0, to: 1 - progress)
                    .stroke(Dungeon.flame, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            Text("\(score)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Dungeon.cream)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.black.opacity(0.3), in: Capsule())
        .accessibilityElement(children: .ignore)
    }
}

/// Sparks, bursts and floating points in one canvas.
private struct Sparks: View {
    var round: GameRound
    var reduceMotion: Bool
    private static let wisp = Color(red: 0.55, green: 0.8, blue: 1)

    var body: some View {
        Canvas { ctx, size in
            for e in round.embers {
                let fade = min(1, e.age / 0.5) * min(1, max(0, e.pos.y / (size.height * 0.2)))
                switch e.kind {
                case .ember:
                    let pulse = reduceMotion ? 1 : 0.85 + 0.15 * sin(e.age * 7 + e.phase)
                    SoftLight.glow(&ctx, at: e.pos, radius: e.radius * 4.5, color: Dungeon.ember, opacity: 0.55 * fade * pulse)
                    dot(&ctx, e.pos, e.radius * 0.7, Dungeon.flame.opacity(fade))
                case .wisp:
                    let back = e.vel.dx > 0 ? -1.0 : 1.0
                    for i in 1...4 {
                        let p = CGPoint(x: e.pos.x + back * Double(i) * 11, y: e.pos.y - e.vel.dy * 0.03 * Double(i))
                        SoftLight.glow(&ctx, at: p, radius: e.radius * (3 - Double(i) * 0.5), color: Self.wisp, opacity: 0.3 * (1 - Double(i) / 5))
                    }
                    SoftLight.glow(&ctx, at: e.pos, radius: e.radius * 4.5, color: Self.wisp, opacity: 0.7)
                    dot(&ctx, e.pos, e.radius * 0.8, .white)
                }
            }
            for s in round.bursts {
                let fade = 1 - s.age / s.life
                dot(&ctx, s.pos, s.radius, (s.kind == .wisp ? Self.wisp : Dungeon.flame).opacity(fade))
            }
            for p in round.popups {
                let t = p.age / 0.9
                let text = Text(p.text).font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(p.kind == .wisp ? Self.wisp : Dungeon.flame)
                ctx.opacity = min(1, 2.2 * (1 - t))
                ctx.draw(ctx.resolve(text), at: CGPoint(x: p.pos.x, y: p.pos.y - 18 - 36 * t))
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: Double, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }
}

/// The score, the best, and what next.
private struct EndCard: View {
    var score: Int
    var best: Int
    var again: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text("\(score)")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Dungeon.flame)
                Text("Best \(best)")
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.muted)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 10) {
                Button("Done", action: done).buttonStyle(EmberButtonStyle(filled: false))
                Button("Again", action: again).buttonStyle(EmberButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(Dungeon.deep.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
    }
}

/// Taps for catches, bonks and the end of the round.
@MainActor
final class GameHaptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .rigid)
    private let notice = UINotificationFeedbackGenerator()

    func prepare() { light.prepare(); heavy.prepare() }
    func caught(_ multiplier: Int) { light.impactOccurred(intensity: min(1, 0.4 + 0.15 * Double(multiplier))) }
    func bonk() { heavy.impactOccurred() }
    func finished() { notice.notificationOccurred(.success) }
}
