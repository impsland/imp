import ImpDesign
import ImpKit
import SwiftUI

/// The games on the stage: the ways in (a flame for Embers and a rune circle for Echo, in the
/// bottom corners, when the Imps are asleep), and for Embers the sparks, the score, the close (X)
/// and the results card. Drawn inside the stage's own timeline, so it reads the engine each frame.
///
/// A game owns the screen from its lesson to the dismissal of its results card: `isPlaying` (and
/// so `EmbersPlaying`) stays true while the card is up, and the stage's chrome comes back at Done.
struct GameLayer: View {
    let engine: StageEngine
    let date: Date
    /// The stage's size (the layers lay out from the safe area now and no longer need it).
    let size: CGSize
    let insets: EdgeInsets
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = engine.reduceMotion = reduceMotion
        let offer = engine.round == nil && engine.echo == nil && !engine.order.isEmpty && !engine.isConnected()
        let lesson = engine.round.map { $0.phase == .fling || $0.phase == .rules } ?? false
        ZStack {
            if let echo = engine.echo {
                EchoLayer(engine: engine, session: echo, date: date, insets: insets, reduceMotion: reduceMotion)
            }
            if let round = engine.round {
                Sparks(round: round, reduceMotion: reduceMotion)
                    .allowsHitTesting(false)
                if round.isOver {
                    GameResultCard(result: round.result(best: engine.best), insets: insets,
                                   again: { engine.startGame() }, done: { engine.endGame() }, howTo: { engine.startGame(tutorial: true) })
                        .transition(GameCard.transition(reduceMotion: reduceMotion))
                } else {
                    GameTopBar(insets: insets, close: { engine.closeGame() }) {
                        if round.phase == .playing {
                            Scoreboard(score: round.score, ring: round.ring, kindle: round.kindleGlow, blaze: round.blazeLevel,
                                       clean: round.isClean, untouched: round.isUntouched)
                        }
                    } below: {
                        if round.phase == .playing, let special = round.special {
                            SpecialBanner(special: special, reduceMotion: reduceMotion)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        if round.phase == .fling {
                            CoachCaption(text: GameRound.caption)
                                .transition(.opacity)
                        }
                    }
                    switch round.phase {
                    case .fling:
                        if let guide = round.guide {
                            CoachFinger(guide: guide, date: date, reduceMotion: reduceMotion,
                                        hidden: engine.bodies[guide.id]?.phase == .dragging)
                                .allowsHitTesting(false)
                        }
                    case .rules:
                        RulesCard(bonk: engine.order.count > 1, date: date, reduceMotion: reduceMotion, insets: insets) { engine.skipLesson() }
                            .transition(GameCard.transition(reduceMotion: reduceMotion))
                    case .countdown:
                        CoachCountdown(number: round.countdown, reduceMotion: reduceMotion)
                            .allowsHitTesting(false)
                    case .playing:
                        EmptyView()
                    }
                    if lesson {
                        SkipLesson(insets: insets) { engine.skipLesson() }
                    }
                }
            }
            if offer {
                HStack {
                    GameButton(symbol: "circle.grid.2x2.fill", tint: EchoArt.accent, glow: EchoArt.accent) { engine.startEcho() }
                        .accessibilityLabel("games.play_echo")
                    Spacer(minLength: 0)
                    GameButton(symbol: "flame.fill", tint: Tone.sparkGold, glow: Tone.sparkEmber) { engine.startGame() }
                        .accessibilityLabel("games.play_embers")
                }
                .padding(.horizontal, Spacing.page + Spacing.snug)
                .padding(.bottom, insets.bottom + Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity)
            }
        }
        .impAnimation(ImpDesign.Motion.spring, value: offer)
        .impAnimation(ImpDesign.Motion.spring, value: engine.round?.isOver)
        .impAnimation(ImpDesign.Motion.spring, value: engine.round?.phase)
        .impAnimation(ImpDesign.Motion.spring, value: engine.round?.special?.kind)
        .impAnimation(ImpDesign.Motion.spring, value: engine.round?.special?.inIntro)
        .impAnimation(ImpDesign.Motion.spring, value: engine.echo?.round.phase)
        .impAnimation(ImpDesign.Motion.spring, value: engine.echo?.round.isLesson)
        .preference(key: EmbersPlaying.self, value: engine.isPlaying)
    }
}

/// Skips the lesson, a quiet text button at the bottom.
struct SkipLesson: View {
    var insets: EdgeInsets
    var action: () -> Void

    var body: some View {
        Button("games.skip", action: action)
            .buttonStyle(CoachSkipStyle())
            .padding(.bottom, insets.bottom + Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.opacity)
    }
}

/// The way into a game: a plain glyph in a bottom corner, with a soft glow.
private struct GameButton: View {
    var symbol: String
    var tint: Color
    var glow: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.icon(.big, weight: .semibold))
                .foregroundStyle(LegibleTint(tint))
                .shadow(color: glow.opacity(Opacity.glow), radius: Spacing.medium)
                .frame(width: Sizing.gameButton, height: Sizing.gameButton)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A game is on (Embers or Echo): the status pill steps aside so the score has the top of the screen.
struct EmbersPlaying: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The score, with a thin ring running down the round. It runs hotter in the Blaze and flashes green
/// when kindling refills it. Two small badges show what is still within reach: a round with no smoke
/// hit, and one where nothing got away; each dims for good when it is lost.
private struct Scoreboard: View {
    var score: Int
    var ring: Double
    var kindle: Double
    var blaze: Double
    var clean: Bool
    var untouched: Bool

    var body: some View {
        HStack(spacing: Spacing.small) {
            ZStack {
                Circle().stroke(Tone.line, lineWidth: 2.5)
                arc(Tone.sparkGold, 1)
                arc(SparkArt.hot, blaze)
                arc(Tone.good, kindle)
            }
            .frame(width: Sizing.gameRing, height: Sizing.gameRing)
            .scaleEffect(1 + 0.3 * kindle)
            Text("\(score)")
                .font(.icon(.big, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Tone.paper)
                .overlay { Text("\(score)").font(.icon(.big, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Tone.sparkGold).opacity(blaze) }
            HStack(spacing: Spacing.snug) {
                badge("smoke.fill", SparkArt.wisp, kept: clean)
                badge("sparkles", SparkArt.gold, kept: untouched)
            }
        }
        .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.snug)
        .background(Tone.scrim, in: Capsule())
        .overlay(Capsule().strokeBorder(SparkArt.hot.opacity(0.55 * blaze), lineWidth: 1.5))
        .shadow(color: SparkArt.hot.opacity(0.6 * blaze), radius: 4 + 14 * blaze)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Score \(score)"))
    }

    private func badge(_ symbol: String, _ color: Color, kept: Bool) -> some View {
        Image(systemName: symbol)
            .font(.icon(.medium, weight: .semibold))
            .foregroundStyle(color)
            .opacity(kept ? 1 : 0.18)
            .scaleEffect(kept ? 1 : 0.7)
            .impAnimation(ImpDesign.Motion.settle, value: kept)
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
    static let wisp = Tone.sparkWisp
    static let hot = Tone.sparkHot
    static let smokeEdge = Tone.sparkSmokeEdge
    static let smokeCore = Tone.sparkSmokeCore
    static let gold = Tone.sparkGold
    static let chain = Tone.sparkChain

    /// The colour of a special phase.
    static func color(for kind: GameRound.Special.Kind) -> Color {
        switch kind {
        case .chain: chain
        case .storm: wisp
        case .shower: gold
        }
    }

    /// A golden spark, falling in the shower.
    static func golden(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 5 * pulse, color: gold, opacity: 0.6 * fade)
        dot(&ctx, p, r * 0.8, Tone.sparkGoldCore.opacity(fade))
    }

    /// An ember of a ring: a pinker halo and a white-hot core, so the ring reads as one thing.
    static func link(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 4.5, color: chain, opacity: 0.55 * fade * pulse)
        dot(&ctx, p, r * 0.7, Tone.sparkChainCore.opacity(fade))
    }

    static func ember(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 4.5, color: Tone.sparkEmber, opacity: 0.55 * fade * pulse)
        dot(&ctx, p, r * 0.7, Tone.sparkGold.opacity(fade))
    }

    /// A green spark with a slow pulse.
    static func kindling(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: Double, fade: Double, pulse: Double) {
        SoftLight.glow(&ctx, at: p, radius: r * 5.5 * pulse, color: Tone.good, opacity: 0.6 * fade)
        dot(&ctx, p, r * 0.75, Tone.sparkKindleCore.opacity(fade))
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
            phaseGlow(&ctx, size)
            var rings: [Int: [CGPoint]] = [:]
            for e in round.embers {
                let rise = min(1, max(0, e.pos.y / (size.height * 0.2)))
                let fade = e.kind == .gold ? min(1, e.age / 0.3) : min(1, e.age / 0.5) * (e.held ? 1 : rise)
                switch e.kind {
                case .ember:
                    let pulse = reduceMotion ? 1 : 0.85 + 0.15 * sin(e.age * 7 + e.phase)
                    if e.ring, let group = e.group {
                        rings[group, default: []].append(e.pos)
                        SparkArt.link(&ctx, at: e.pos, radius: e.radius, fade: fade, pulse: pulse)
                    } else {
                        SparkArt.ember(&ctx, at: e.pos, radius: e.radius, fade: fade, pulse: pulse)
                    }
                case .gold:
                    SparkArt.golden(&ctx, at: e.pos, radius: e.radius, fade: fade, pulse: reduceMotion ? 1 : 0.85 + 0.15 * sin(e.age * 9 + e.phase))
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
                    SparkArt.dot(&ctx, e.pos, e.radius * 0.8, Tone.paper)
                }
            }
            // A thin thread through the embers of a ring, so it reads as one thing to take in one flight.
            for points in rings.values where points.count > 1 {
                var path = Path()
                path.addLines(points)
                if points.count > 2 { path.closeSubpath() }
                ctx.stroke(path, with: .color(SparkArt.chain.opacity(0.32)), lineWidth: 1.5)
            }
            for s in round.bursts {
                let fade = 1 - s.age / s.life
                let color: Color = switch s.kind {
                case .wisp: SparkArt.wisp
                case .kindling: Tone.good
                case .smoke: SparkArt.smokeEdge
                case .ember: Tone.sparkGold
                case .gold: SparkArt.gold
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

    /// A soft wash from the top of the screen while a special phase is on: orange-pink for rings,
    /// blue for the wisp storm, gold for the shower. It swells in and fades out with the phase.
    private func phaseGlow(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let special = round.special else { return }
        let level = min(1, special.elapsed / 0.6) * min(1, special.remaining / 0.8)
        let color = SparkArt.color(for: special.kind)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 220)),
                 with: .linearGradient(Gradient(colors: [color.opacity(0.26 * level), color.opacity(0)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: 220)))
    }

    private func popup(_ ctx: inout GraphicsContext, _ p: GameRound.Popup) {
        let t = p.age / p.style.life
        let color: Color = switch p.kind {
        case .wisp: SparkArt.wisp
        case .kindling: Tone.good
        case .smoke: SparkArt.smokeEdge
        case .gold: SparkArt.gold
        case .ember: p.style == .note ? SparkArt.hot : Tone.sparkGold
        }
        let text = Text(p.text).font(.system(size: p.style.size, weight: .bold, design: .rounded)).foregroundStyle(color)
        var c = ctx
        c.opacity = p.style == .award ? min(1, 3 * (1 - t)) : min(1, 2.2 * (1 - t))
        c.translateBy(x: p.pos.x, y: p.pos.y - 18 - p.style.rise * t)
        if p.style == .cheer || p.style == .award, !reduceMotion {
            let s = 0.7 + 0.3 * min(1, p.age * 9) + 0.06 * sin(p.age * 5)
            c.scaleBy(x: s, y: s)
        }
        c.draw(c.resolve(text), at: .zero)
    }
}


/// What the end of a round says, for the shared results card.
extension GameRound {
    func result(best: Int) -> GameResult {
        var stats = [GameStat(value: "\(bestCombo)", label: String(localized: "games.stat.combo"))]
        if wavesJudged > 0 { stats.append(GameStat(value: "\(perfectWaves)/\(wavesJudged)", label: String(localized: "games.stat.waves"))) }
        if escaped > 0 { stats.append(GameStat(value: "\(escaped)", label: String(localized: "games.stat.escaped"))) }
        var prizes: [GamePrize] = []
        if flawless {
            prizes.append(GamePrize(symbol: "sparkles", color: SparkArt.gold, title: String(localized: "games.prize.flawless"),
                                    points: Self.flawlessBonus,
                                    note: flawlessRounds > 1 ? Self.plural("games.prize.times", flawlessRounds) : nil))
        }
        if cleanBurn {
            prizes.append(GamePrize(symbol: "smoke.fill", color: SparkArt.wisp, title: String(localized: "games.prize.clean"),
                                    points: Self.cleanBonus,
                                    note: cleanStreak > 1 ? Self.plural("games.prize.in_a_row", cleanStreak) : nil))
        }
        return GameResult(title: String(localized: "games.embers"), score: score, best: best, isRecord: isRecord, stats: stats, prizes: prizes)
    }

    private static func plural(_ key: String, _ count: Int) -> String {
        String.localizedStringWithFormat(NSLocalizedString(key, comment: ""), count)
    }
}

/// What a special phase is called, and what to do in it.
extension GameRound.Special.Kind {
    var title: String {
        switch self {
        case .chain: String(localized: "Ring time!")
        case .storm: String(localized: "Wisp storm!")
        case .shower: String(localized: "Golden shower!")
        }
    }

    var hint: String {
        switch self {
        case .chain: String(localized: "Take each ring in one flight")
        case .storm: String(localized: "Blue wisps pay five")
        case .shower: String(localized: "Catch the gold")
        }
    }
}

/// Announces a special phase, big for a moment, then a slim label with the phase running down.
private struct SpecialBanner: View {
    var special: GameRound.Special
    var reduceMotion: Bool

    var body: some View {
        let color = SparkArt.color(for: special.kind)
        VStack(spacing: Spacing.snug) {
            Text(special.kind.title)
                .font((special.inIntro ? Typeface.title : Typeface.label).weight(.heavy))
                .foregroundStyle(color)
                .shadow(color: color.opacity(special.inIntro ? 0.7 : 0), radius: Spacing.medium)
                .scaleEffect(special.inIntro && !reduceMotion ? 1 + 0.08 * sin(special.elapsed * 6) : 1)
            if special.inIntro {
                Text(special.kind.hint)
                    .font(Typeface.body)
                    .foregroundStyle(Tone.paper)
            } else {
                Capsule().fill(color.opacity(0.25)).frame(width: Sizing.meter, height: Spacing.tight)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: Sizing.meter * (1 - special.progress), height: Spacing.tight)
                    }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.page).padding(.vertical, special.inIntro ? Spacing.medium : Spacing.small)
        .background(Tone.scrim, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .accessibilityHidden(true)
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

    /// A whole wave: two quick taps, harder for every wave in a row.
    func perfect(_ streak: Int) {
        let force = min(1, 0.55 + 0.15 * Double(streak))
        soft.impactOccurred(intensity: force)
        later(0.07) { self.light.impactOccurred(intensity: force) }
    }

    /// A ring in one flight: a knock, then a settling.
    func ring() {
        heavy.impactOccurred(intensity: 0.7)
        later(0.1) { self.soft.impactOccurred(intensity: 1) }
        later(0.2) { self.soft.impactOccurred(intensity: 0.5) }
    }

    /// A special phase begins: a firm tap with a softer one behind it.
    func phase() {
        heavy.impactOccurred(intensity: 0.8)
        later(0.12) { self.soft.impactOccurred(intensity: 0.7) }
    }

    /// No smoke all round: a clean, bright success.
    func cleanBurn() { notice.notificationOccurred(.success) }

    /// Nothing got away: taps climbing, then the success.
    func flawless() {
        for i in 0..<6 { later(0.08 * Double(i)) { self.light.impactOccurred(intensity: 0.35 + 0.13 * Double(i)) } }
        later(0.55) { self.notice.notificationOccurred(.success) }
        later(0.8) { self.heavy.impactOccurred(intensity: 1) }
    }

    /// A new best gets a second tap after the success.
    func finished(best: Bool) {
        notice.notificationOccurred(.success)
        guard best else { return }
        later(0.22) { self.heavy.impactOccurred(intensity: 0.7) }
    }

    private func later(_ seconds: Double, _ tap: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            tap()
        }
    }
}
