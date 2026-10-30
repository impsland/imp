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
        let lesson = engine.round.map { $0.phase == .fling || $0.phase == .rules } ?? false
        ZStack {
            if let round = engine.round {
                Sparks(round: round, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                if round.isOver {
                    EndCard(score: round.score, best: engine.best, isRecord: round.isRecord,
                            again: { engine.startGame() }, done: { engine.endGame() }, howTo: { engine.startGame(tutorial: true) })
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    switch round.phase {
                    case .playing:
                        Scoreboard(score: round.score, ring: round.ring, kindle: round.kindleGlow, blaze: round.blazeLevel)
                            .position(x: size.width / 2, y: insets.top + 24)
                            .allowsHitTesting(false)
                    case .fling:
                        CoachCaption(text: GameRound.caption)
                            .frame(maxWidth: size.width - 32)
                            .position(x: size.width / 2, y: insets.top + 24)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                        if let guide = round.guide {
                            CoachFinger(guide: guide, date: date, reduceMotion: reduceMotion,
                                        hidden: engine.bodies[guide.id]?.phase == .dragging)
                                .allowsHitTesting(false)
                        }
                    case .rules:
                        RulesCard(bonk: engine.order.count > 1, date: date, reduceMotion: reduceMotion) { engine.skipLesson() }
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    case .countdown:
                        CoachCountdown(number: round.countdown, reduceMotion: reduceMotion)
                            .position(x: size.width / 2, y: size.height / 2)
                            .allowsHitTesting(false)
                    }
                }
                if lesson, !round.isOver {
                    Button("Skip") { engine.skipLesson() }
                        .buttonStyle(CoachSkipStyle())
                        .position(x: size.width / 2, y: size.height - insets.bottom - 36)
                        .transition(.opacity)
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
        .animation(.spring(duration: 0.4), value: engine.round?.phase)
        .preference(key: EmbersPlaying.self, value: engine.isPlaying)
    }
}

/// A round of Embers is on: the status pill steps aside so the score has the top of the screen.
struct EmbersPlaying: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The score, with a thin ring running down the round. It runs hotter in the Blaze and flashes green
/// when kindling refills it.
private struct Scoreboard: View {
    var score: Int
    var ring: Double
    var kindle: Double
    var blaze: Double

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Dungeon.cardEdge, lineWidth: 2.5)
                arc(Dungeon.flame, 1)
                arc(SparkArt.hot, blaze)
                arc(Dungeon.good, kindle)
            }
            .frame(width: 16, height: 16)
            .scaleEffect(1 + 0.3 * kindle)
            Text("\(score)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Dungeon.cream)
                .overlay { Text("\(score)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Dungeon.flame).opacity(blaze) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(SparkArt.hot.opacity(0.55 * blaze), lineWidth: 1.5))
        .shadow(color: SparkArt.hot.opacity(0.6 * blaze), radius: 4 + 14 * blaze)
        .accessibilityElement(children: .ignore)
    }

    private func arc(_ color: Color, _ opacity: Double) -> some View {
        Circle().trim(from: 0, to: ring)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .opacity(opacity)
    }
}

/// The look of every spark, shared by the stage and the little icons on the rules card.
enum SparkArt {
    static let wisp = Color(red: 0.55, green: 0.8, blue: 1)
    static let hot = Color(red: 1, green: 0.5, blue: 0.24)
    static let smokeEdge = Color(red: 0.6, green: 0.54, blue: 0.74)
    static let smokeCore = Color(red: 0.09, green: 0.06, blue: 0.14)

    static func ember(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 4.5, color: Dungeon.ember, opacity: 0.55 * fade * pulse)
        dot(&ctx, p, r * 0.7, Dungeon.flame.opacity(fade))
    }

    /// A green spark with a slow pulse.
    static func kindling(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 5.5 * pulse, color: Dungeon.good, opacity: 0.6 * fade)
        dot(&ctx, p, r * 0.75, Color(red: 0.8, green: 1, blue: 0.82).opacity(fade))
    }

    /// A soft blurred blob with a lighter rim and a darker core, so it reads against the dark wall.
    static func smoke(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, t: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 1.35, color: smokeEdge, opacity: 0.5 * fade)
        for i in 0..<3 {
            let a = t * 0.6 + Double(i) * 2.1
            let q = CGPoint(x: p.x + cos(a) * r * 0.26, y: p.y + sin(a * 1.3) * r * 0.2)
            SoftLight.glow(&ctx, at: q, radius: r * 0.85, color: smokeCore, opacity: 0.62 * fade)
        }
    }

    static func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: Double, _ color: Color) {
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
    }
}

/// Sparks, smoke, bursts, the Blaze's glow and floating points in one canvas.
private struct Sparks: View {
    var round: GameRound
    var reduceMotion: Bool

    var body: some View {
        Canvas { ctx, size in
            blaze(&ctx, size)
            for e in round.embers {
                let rise = min(1, max(0, e.pos.y / (size.height * 0.2)))
                let fade = min(1, e.age / 0.5) * (e.held ? 1 : rise)
                switch e.kind {
                case .ember:
                    let pulse = reduceMotion ? 1 : 0.85 + 0.15 * sin(e.age * 7 + e.phase)
                    SparkArt.ember(&ctx, at: e.pos, radius: e.radius, fade: fade, pulse: pulse)
                case .kindling:
                    let pulse = reduceMotion ? 1 : 0.88 + 0.12 * sin(e.age * 3.2 + e.phase)
                    SparkArt.kindling(&ctx, at: e.pos, radius: e.radius, fade: fade, pulse: pulse)
                case .smoke:
                    SparkArt.smoke(&ctx, at: e.pos, radius: e.radius, fade: min(1, e.age / 1.2) * rise, t: reduceMotion ? 0 : e.age + e.phase)
                case .wisp:
                    let back = e.vel.dx > 0 ? -1.0 : 1.0
                    for i in 1...4 {
                        let p = CGPoint(x: e.pos.x + back * Double(i) * 11, y: e.pos.y - e.vel.dy * 0.03 * Double(i))
                        SoftLight.glow(&ctx, at: p, radius: e.radius * (3 - Double(i) * 0.5), color: SparkArt.wisp, opacity: 0.3 * (1 - Double(i) / 5))
                    }
                    SoftLight.glow(&ctx, at: e.pos, radius: e.radius * 4.5, color: SparkArt.wisp, opacity: 0.7)
                    SparkArt.dot(&ctx, e.pos, e.radius * 0.8, .white)
                }
            }
            for s in round.bursts {
                let fade = 1 - s.age / s.life
                let color: Color = switch s.kind {
                case .wisp: SparkArt.wisp
                case .kindling: Dungeon.good
                case .smoke: SparkArt.smokeEdge
                case .ember: Dungeon.flame
                }
                SparkArt.dot(&ctx, s.pos, s.radius, color.opacity(s.kind == .smoke ? 0.7 * fade : fade))
            }
            for p in round.popups { popup(&ctx, p) }
        }
        .accessibilityHidden(true)
    }

    /// A warm glow rising from the bottom edge for the last seconds.
    private func blaze(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let level = round.blazeLevel
        guard level > 0.01 else { return }
        let band = size.height * 0.3
        ctx.fill(Path(CGRect(x: 0, y: size.height - band, width: size.width, height: band)),
                 with: .linearGradient(Gradient(colors: [SparkArt.hot.opacity(0), SparkArt.hot.opacity(0.3 * level)]),
                                       startPoint: CGPoint(x: 0, y: size.height - band), endPoint: CGPoint(x: 0, y: size.height)))
        for i in 0..<5 {
            let flicker = reduceMotion ? 1 : 0.8 + 0.2 * sin(round.elapsed * 2.4 + Double(i) * 1.7)
            let p = CGPoint(x: size.width * (Double(i) + 0.5) / 5, y: size.height + 10)
            SoftLight.glow(&ctx, at: p, radius: 200 * flicker, color: SparkArt.hot, opacity: 0.4 * level * flicker, squash: 0.85)
        }
    }

    private func popup(_ ctx: inout GraphicsContext, _ p: GameRound.Popup) {
        let t = p.age / p.style.life
        let color: Color = switch p.kind {
        case .wisp: SparkArt.wisp
        case .kindling: Dungeon.good
        case .smoke: SparkArt.smokeEdge
        case .ember: p.style == .note ? SparkArt.hot : Dungeon.flame
        }
        let text = Text(p.text).font(.system(size: p.style.size, weight: .bold, design: .rounded)).foregroundStyle(color)
        var c = ctx
        c.opacity = min(1, 2.2 * (1 - t))
        c.translateBy(x: p.pos.x, y: p.pos.y - 18 - p.style.rise * t)
        if p.style == .cheer, !reduceMotion {
            let s = 0.7 + 0.3 * min(1, p.age * 9) + 0.06 * sin(p.age * 5)
            c.scaleBy(x: s, y: s)
        }
        c.draw(c.resolve(text), at: .zero)
    }
}

/// The score, the best, and what next.
private struct EndCard: View {
    var score: Int
    var best: Int
    var isRecord: Bool
    var again: () -> Void
    var done: () -> Void
    var howTo: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text("\(score)")
                    .font(.system(size: 58, weight: .bold, design: .rounded))
                    .foregroundStyle(Dungeon.flame)
                if isRecord {
                    Text("New best!")
                        .font(.system(.callout, design: .rounded, weight: .bold))
                        .foregroundStyle(SparkArt.hot)
                } else {
                    Text("Best \(best)")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(Dungeon.muted)
                }
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button("Done", action: done).buttonStyle(EmberButtonStyle(filled: false))
                    Button("Again", action: again).buttonStyle(EmberButtonStyle())
                }
                Button("How to play", action: howTo)
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.muted)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)
        .frame(maxWidth: 300)
        .background(Dungeon.deep.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
    }
}

/// Taps for catches, kindling, smoke, the Blaze, bonks, the countdown and the end of the round.
@MainActor
final class GameHaptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let heavy = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let notice = UINotificationFeedbackGenerator()

    func prepare() { light.prepare(); heavy.prepare(); soft.prepare(); notice.prepare() }
    func caught(_ multiplier: Int) { light.impactOccurred(intensity: min(1, 0.4 + 0.15 * Double(multiplier))) }
    func bonk() { heavy.impactOccurred() }
    func kindled() { soft.impactOccurred(intensity: 0.8) }
    func smoked() { notice.notificationOccurred(.warning) }
    func blaze() { heavy.impactOccurred() }
    func tick(_ n: Int) { n > 0 ? light.impactOccurred(intensity: 0.5) : heavy.impactOccurred(intensity: 0.8) }
    /// A new best gets a second tap after the success.
    func finished(best: Bool) {
        notice.notificationOccurred(.success)
        guard best else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            heavy.impactOccurred(intensity: 0.7)
        }
    }
}
