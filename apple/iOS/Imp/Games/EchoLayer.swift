import ImpDesign
import ImpKit
import SwiftUI

/// The look of Echo: four runes, each with its own colour and sign, so no one is told apart by
/// colour alone.
enum EchoArt {
    static let accent = Tone.echoAccent
    static let colors: [Color] = [Tone.sparkEmber, Tone.good, SparkArt.wisp, accent]
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
        ctx.fill(stone, with: .color(Tone.deep.opacity(0.88)))
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
            lit.shading = .color(Tone.paper.opacity(min(1, g * 1.2)))
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

/// Echo on the stage: the taps on the runes, the score and lives, the close (X), the guided step, the
/// rules, the countdown and the results card. The Imps and the runes under them are drawn by the stage itself.
struct EchoLayer: View {
    let engine: StageEngine
    let session: EchoSession
    let date: Date
    let insets: EdgeInsets
    let reduceMotion: Bool

    var body: some View {
        let round = session.round
        let ready = session.field != .zero
        let centers = EchoSession.centers(in: session.field)
        let active = round.phase == .watching || round.phase == .repeating || round.phase == .between
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
                GameResultCard(result: round.result(best: session.best(imps: session.imps), imps: session.imps), insets: insets,
                               again: { engine.startEcho() }, done: { engine.endEcho() }, howTo: { engine.startEcho(tutorial: true) })
                    .transition(GameCard.transition(reduceMotion: reduceMotion))
            } else {
                GameTopBar(insets: insets, close: { engine.closeEcho() }) {
                    if round.isScoring {
                        VStack(spacing: Spacing.small) {
                            EchoBoard(score: round.score, lives: round.lives)
                            EchoStatus(phase: round.phase, outcome: session.outcome, length: round.length, position: round.position)
                        }
                    }
                } below: {
                    if active, round.isLesson {
                        CoachCaption(text: EchoLesson.caption(watching: round.phase != .repeating, slipped: session.outcome == .slipped))
                            .transition(.opacity)
                    }
                }
                switch round.phase {
                case .rules:
                    EchoRulesCard(insets: insets) { engine.skipEchoLesson() }
                        .transition(GameCard.transition(reduceMotion: reduceMotion))
                case .countdown:
                    CoachCountdown(number: round.countdown, reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                case .watching, .repeating, .between, .over:
                    EmptyView()
                }
                if round.isLesson || round.phase == .rules {
                    SkipLesson(insets: insets) { engine.skipEchoLesson() }
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
            .frame(width: Sizing.echoPad, height: Sizing.echoPad)
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
                let text = Text(p.text).font(p.big ? Typeface.title : Typeface.label).foregroundStyle(p.color)
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
        HStack(spacing: Spacing.medium) {
            Text(verbatim: "\(score)")
                .font(.icon(.big, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Tone.paper)
            HStack(spacing: Spacing.tight) {
                ForEach(0..<EchoRound.lives, id: \.self) { i in
                    Image(systemName: i < lives ? "heart.fill" : "heart")
                        .font(.icon(.large, weight: .bold))
                        .foregroundStyle(SparkArt.chain.opacity(i < lives ? 1 : 0.35))
                        .scaleEffect(i < lives ? 1 : 0.8)
                }
            }
            .impAnimation(ImpDesign.Motion.settle, value: lives)
        }
        .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.snug)
        .background(Tone.scrim, in: Capsule())
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
        HStack(spacing: Spacing.small) {
            Image(systemName: symbol)
                .font(.icon(.medium, weight: .bold))
            Text(label)
                .font(Typeface.caption)
            HStack(spacing: length > 10 ? 3 : 5) {
                ForEach(0..<length, id: \.self) { i in
                    Circle()
                        .fill(i < filled ? EchoArt.accent : Tone.line)
                        .frame(width: length > 10 ? 5 : 7, height: length > 10 ? 5 : 7)
                }
            }
        }
        .foregroundStyle(phase == .repeating ? EchoArt.accent : Tone.paper)
        .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.snug)
        .background(Tone.scrim, in: Capsule())
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

/// What the end of a round says, for the shared results card.
extension EchoRound {
    func result(best: Int, imps: Int) -> GameResult {
        GameResult(title: String(localized: "games.echo"), score: score, best: best, imps: imps, isRecord: isRecord,
                   stats: [GameStat(value: "\(level)", label: String(localized: "games.stat.longest")),
                           GameStat(value: "\(mistakes)", label: String(localized: "games.stat.slips"))],
                   prizes: completed ? [GamePrize(symbol: "sparkles", color: SparkArt.gold,
                                                  title: String(localized: "games.prize.perfect_echo"), points: nil, note: nil)] : [])
    }
}
