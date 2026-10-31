import ImpKit
import SwiftUI

/// The look of Echo: four runes, each with its own colour and sign, so no one is told apart by
/// colour alone.
enum EchoArt {
    static let accent = Color(red: 0.72, green: 0.6, blue: 1)
    static let colors: [Color] = [Dungeon.ember, Dungeon.good, SparkArt.wisp, accent]
    static let symbols = ["flame.fill", "leaf.fill", "drop.fill", "moon.fill"]
    static var names: [String] {
        [String(localized: "Flame"), String(localized: "Leaf"), String(localized: "Drop"), String(localized: "Moon")]
    }
    /// Half the width of a stone.
    static let stone = 46.0
}

/// The runes on the dungeon floor, under the Imps that hop on them. Drawn in the stage's own
/// timeline, a rune that is lit glows, and the one to tap next pulses when the player is stuck.
struct EchoFloor: View {
    let engine: StageEngine
    let date: Date
    let reduceMotion: Bool

    var body: some View {
        if let echo = engine.echo, echo.field != .zero {
            let round = echo.round
            let centers = EchoSession.centers(in: echo.field)
            let hint = round.hinted
            let glow = round.glow
            let cue = round.phase == .repeating
            Canvas { ctx, _ in
                let t = date.timeIntervalSinceReferenceDate
                for i in 0..<EchoRound.runes {
                    rune(&ctx, i, at: centers[i], glow: glow[i], hinted: hint == i, cue: cue, t: t)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func rune(_ ctx: inout GraphicsContext, _ i: Int, at c: CGPoint, glow g: Double, hinted: Bool, cue: Bool, t: Double) {
        let color = EchoArt.colors[i]
        let breath = reduceMotion || !cue ? 0 : 0.5 + 0.5 * sin(t * 2.2 + Double(i) * 1.3)
        SoftLight.glow(&ctx, at: c, radius: 110 + 60 * g, color: color, opacity: 0.12 + 0.05 * breath + 0.5 * g)
        let r = EchoArt.stone * (reduceMotion ? 1 : 1 + 0.08 * g)
        let stone = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(stone, with: .color(Dungeon.deep.opacity(0.88)))
        ctx.fill(stone, with: .color(color.opacity(0.1 + 0.05 * breath + 0.5 * g)))
        ctx.stroke(stone, with: .color(color.opacity(0.4 + 0.1 * breath + 0.6 * g)), lineWidth: 2.5 + 2 * g)
        // The sign: in the rune's colour, going white as it lights.
        let sign = ctx.resolve(Image(systemName: EchoArt.symbols[i]))
        let scale = 30 / max(sign.size.width, sign.size.height)
        let box = CGRect(x: c.x - sign.size.width * scale / 2, y: c.y - sign.size.height * scale / 2,
                         width: sign.size.width * scale, height: sign.size.height * scale)
        var base = sign
        base.shading = .color(color.opacity(0.62))
        ctx.draw(base, in: box)
        if g > 0.02 {
            var lit = sign
            lit.shading = .color(.white.opacity(min(1, g * 1.2)))
            ctx.draw(lit, in: box)
        }
        if hinted {
            let u = reduceMotion ? 0.3 : (t * 1.4).truncatingRemainder(dividingBy: 1)
            let ring = r + 6 + 16 * u
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: 2 * ring, height: 2 * ring)),
                       with: .color(color.opacity(reduceMotion ? 0.8 : 0.9 * (1 - u))), lineWidth: 3)
        }
    }
}

/// Echo on the stage: the taps on the runes, the score and lives, the guided step, the rules, the
/// countdown and the end card. The Imps and the runes under them are drawn by the stage itself.
struct EchoLayer: View {
    let engine: StageEngine
    let session: EchoSession
    let date: Date
    let size: CGSize
    let insets: EdgeInsets
    let reduceMotion: Bool

    var body: some View {
        let round = session.round
        let ready = session.field != .zero
        let centers = EchoSession.centers(in: session.field)
        let active = round.phase == .watching || round.phase == .repeating || round.phase == .between
        let top = insets.top + 24
        ZStack {
            if active, ready {
                ForEach(0..<EchoRound.runes, id: \.self) { i in
                    RuneButton(rune: i, center: centers[i]) { engine.tapRune($0) }
                }
            }
            EchoFx(popups: session.popups, sparks: session.sparks, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
            if ready, round.phase == .repeating, let next = round.isLesson ? round.expected : round.hinted {
                EchoTapHint(center: centers[next], color: EchoArt.colors[next], date: date, reduceMotion: reduceMotion)
            }
            if round.isOver {
                EchoEndCard(round: round, best: session.best,
                            again: { engine.startEcho() }, done: { engine.endEcho() }, howTo: { engine.startEcho(tutorial: true) })
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                switch round.phase {
                case .watching, .repeating, .between:
                    if round.isLesson {
                        CoachCaption(text: EchoLesson.caption(watching: round.phase != .repeating, slipped: session.outcome == .slipped))
                            .frame(maxWidth: size.width - 32)
                            .position(x: size.width / 2, y: top)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 8) {
                            EchoBoard(score: round.score, lives: round.lives)
                            EchoStatus(phase: round.phase, outcome: session.outcome, length: round.length, position: round.position)
                        }
                        .position(x: size.width / 2, y: top + 24)
                        .allowsHitTesting(false)
                        Button { engine.stopEcho() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Dungeon.muted)
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("End Echo")
                        .position(x: 34, y: top)
                    }
                case .rules:
                    EchoRulesCard { engine.skipEchoLesson() }
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                case .countdown:
                    CoachCountdown(number: round.countdown, reduceMotion: reduceMotion)
                        .position(x: size.width / 2, y: size.height / 2)
                        .allowsHitTesting(false)
                case .over:
                    EmptyView()
                }
                if round.isLesson || round.phase == .rules {
                    Button("Skip") { engine.skipEchoLesson() }
                        .buttonStyle(CoachSkipStyle())
                        .position(x: size.width / 2, y: size.height - insets.bottom - 36)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// A tap on a rune, felt the moment the finger lands. Unseen: the rune itself is drawn under the Imps.
private struct RuneButton: View {
    var rune: Int
    var center: CGPoint
    var action: (Int) -> Void
    @State private var down = false

    var body: some View {
        Color.clear
            .frame(width: 128, height: 128)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !down else { return }
                    down = true
                    action(rune)
                }
                .onEnded { _ in down = false })
            .position(center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(EchoArt.names[rune]) rune")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { action(rune) }
    }
}

/// Words that float up, and sparks in the runes' colours.
private struct EchoFx: View {
    var popups: [EchoSession.Popup]
    var sparks: [EchoSession.Spark]
    var reduceMotion: Bool

    var body: some View {
        Canvas { ctx, _ in
            for s in sparks {
                let fade = 1 - s.age / s.life
                SparkArt.dot(&ctx, s.pos, s.radius, EchoArt.colors[s.rune].opacity(fade))
            }
            for p in popups {
                let t = p.age / p.life
                let text = Text(p.text).font(.system(size: p.big ? 28 : 16, weight: .bold, design: .rounded)).foregroundStyle(p.color)
                var c = ctx
                c.opacity = min(1, 2.2 * (1 - t))
                c.translateBy(x: p.pos.x, y: p.pos.y - 10 - (p.big ? 22 : 30) * t)
                if p.big, !reduceMotion {
                    let s = 0.7 + 0.3 * min(1, p.age * 9) + 0.05 * sin(p.age * 5)
                    c.scaleBy(x: s, y: s)
                }
                c.draw(c.resolve(text), at: .zero)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The score and the lives.
private struct EchoBoard: View {
    var score: Int
    var lives: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(score)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Dungeon.cream)
            HStack(spacing: 4) {
                ForEach(0..<EchoRound.lives, id: \.self) { i in
                    Image(systemName: i < lives ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(SparkArt.chain.opacity(i < lives ? 1 : 0.35))
                        .scaleEffect(i < lives ? 1 : 0.8)
                }
            }
            .animation(.spring(duration: 0.35), value: lives)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.black.opacity(0.3), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Score \(score), lives \(lives)")
    }
}

/// Whose turn it is, and how far along the sequence the player is.
private struct EchoStatus: View {
    var phase: EchoRound.Phase
    var outcome: EchoSession.Outcome
    var length: Int
    var position: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
            Text(label)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
            HStack(spacing: length > 10 ? 3 : 5) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? EchoArt.accent : Dungeon.cardEdge)
                        .frame(width: length > 10 ? 5 : 7, height: length > 10 ? 5 : 7)
                }
            }
        }
        .foregroundStyle(phase == .repeating ? EchoArt.accent : Dungeon.cream)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.26), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var filled: Int {
        switch phase {
        case .repeating: position
        case .between: outcome == .cleared ? length : 0
        default: 0
        }
    }

    private var symbol: String {
        switch phase {
        case .watching: "eye.fill"
        case .repeating: "hand.tap.fill"
        default: outcome == .slipped ? "arrow.counterclockwise" : "checkmark.circle.fill"
        }
    }

    private var label: String {
        switch phase {
        case .watching: String(localized: "Watch")
        case .repeating: String(localized: "Your turn")
        default: outcome == .slipped ? String(localized: "Watch again") : String(localized: "Nice!")
        }
    }
}

/// The score, the best, how far the sequence got, and what next.
private struct EchoEndCard: View {
    var round: EchoRound
    var best: Int
    var again: () -> Void
    var done: () -> Void
    var howTo: () -> Void

    var body: some View {
        CardFit {
            VStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text(verbatim: "\(round.score)")
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                        .foregroundStyle(EchoArt.accent)
                    if round.isRecord {
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
                if round.completed {
                    Prize(symbol: "sparkles", color: SparkArt.gold, title: String(localized: "Perfect echo!"), points: nil,
                          note: String(localized: "Every rune, all the way"))
                }
                ViewThatFits {
                    HStack(alignment: .top, spacing: 22) { stats }
                    VStack(spacing: 8) { stats }
                }
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
        }
        .gameCard(maxWidth: 320, bottom: 14)
    }

    @ViewBuilder private var stats: some View {
        Stat(value: "\(round.level)", label: String(localized: "Longest echo"))
        Stat(value: "\(round.mistakes)", label: String(localized: "Slips"))
    }
}
