import ImpDesign
import ImpKit
import SwiftUI

/// A round of Echo on the stage: the pure rules (`EchoRound`), plus everything that touches the
/// world around them. It tells the stage where each Imp should be (hopping from rune to rune) and
/// how it should act, and keeps the floating words and sparks, the haptics, the tones and the
/// best score. Driven once a frame by the engine, like the engine drives `GameRound`.
@MainActor
final class EchoSession {
    nonisolated static let bestKey = "echoBest"

    private(set) var round: EchoRound
    /// Where the Imps may be (set every frame by the engine).
    private(set) var field = CGRect.zero
    private(set) var popups: [Popup] = []
    private(set) var sparks: [Spark] = []
    private(set) var outcome = Outcome.none

    enum Outcome { case none, cleared, slipped }

    struct Popup {
        var text: String
        var pos: CGPoint
        var color: Color
        var big = false
        var age = 0.0
        var life: Double { big ? 1.7 : 0.9 }
    }

    struct Spark {
        var pos: CGPoint
        var vel: CGVector
        var rune: Int
        var radius: Double
        var life: Double
        var age = 0.0
    }

    private struct Leap {
        var from: CGPoint
        var to: CGPoint
        var start: Double
        var duration: Double
    }

    /// How an Imp should act: its place for this frame, or a performance.
    struct Cue {
        var id: UUID
        var performance: Performance
        /// Dizzy for this long, in seconds.
        var dizzy = 0.0
    }

    struct Output {
        var places: [UUID: CGPoint] = [:]
        var cues: [Cue] = []
    }

    /// The Imps, where they are now, and when.
    struct Stage {
        var ids: [UUID]
        var positions: [UUID: CGPoint]
        var date: Date
        var calm: Bool
    }

    private var leaps: [UUID: Leap] = [:]
    private var clock = 0.0
    private var turn = 0
    private let haptics = EchoHaptics()
    private let sound = EchoSound()
    private let game = GameHaptics()

    var best: Int { UserDefaults.standard.integer(forKey: Self.bestKey) }

    init(coaching: Bool) {
        round = EchoRound(coaching: coaching)
        haptics.prepare()
        sound.prepare()
        game.prepare()
        if coaching { AccessibilityNotification.Announcement(String(localized: "Watch the Imps light the runes")).post() }
    }

    /// The tap is over: the engine and tones rest.
    func close() {
        haptics.stop()
        sound.stop()
    }

    // MARK: Where the runes are

    /// The four runes in a square, in the open middle of the stage: flame and leaf above, drop and moon below.
    static func centers(in field: CGRect) -> [CGPoint] {
        let xs = [0.27, 0.73], ys = [0.24, 0.76]
        return ys.flatMap { y in xs.map { x in CGPoint(x: field.minX + field.width * x, y: field.minY + field.height * y) } }
    }

    func center(_ rune: Int) -> CGPoint { Self.centers(in: field)[min(max(rune, 0), EchoRound.runes - 1)] }

    /// Where an Imp stands to light a rune: on the stone, side by side when there are several.
    private func stand(_ rune: Int, slot: Int) -> CGPoint {
        let c = center(rune)
        return CGPoint(x: c.x + (Double(slot % 3) - 1) * 24, y: c.y - 30 + Double(slot % 3 == 1 ? 6 : 0))
    }

    // MARK: Every frame

    func advance(_ dt: Double, in field: CGRect, stage: Stage) -> Output {
        self.field = field
        clock += dt
        var out = Output()
        let lesson = round.isLesson
        handle(round.advance(dt), lesson: lesson, stage: stage, out: &out)
        move(dt, stage: stage, out: &out)
        return out
    }

    /// The player taps a rune.
    func tap(_ rune: Int, in field: CGRect, stage: Stage) -> Output {
        self.field = field
        var out = Output()
        let lesson = round.isLesson
        handle(round.tap(rune), lesson: lesson, stage: stage, out: &out)
        return out
    }

    /// Skips the guided step or the rules.
    func skip(in field: CGRect, stage: Stage) -> Output {
        self.field = field
        var out = Output()
        handle(round.nextStep(), lesson: false, stage: stage, out: &out)
        return out
    }

    /// The player is done: the round ends with what it earned.
    func stop(in field: CGRect, stage: Stage) -> Output {
        self.field = field
        var out = Output()
        handle(round.stop(), lesson: false, stage: stage, out: &out)
        return out
    }

    /// How an Imp looks now.
    func mood(of id: UUID, dizzy: Bool) -> Mood {
        if dizzy { return .dizzy }
        if leaps[id] != nil { return .excited }
        switch round.phase {
        case .watching: return .curious
        case .repeating: return .listening
        case .between: return outcome == .slipped ? .annoyed : .happy
        case .over: return round.completed ? .excited : .content
        case .rules, .countdown: return .idle
        }
    }

    // MARK: Events

    private func handle(_ events: [EchoRound.Event], lesson: Bool, stage: Stage, out: inout Output) {
        let voiceOver = UIAccessibility.isVoiceOverRunning
        for event in events {
            switch event {
            case .hop(let rune, _):
                guard let id = pick(stage) else { continue }
                leap(id, to: rune, duration: EchoRound.lead(for: round.length), stage: stage)
                out.cues.append(Cue(id: id, performance: Performance(key: "echo", steps: [
                    AnticStep(duration: EchoRound.lead(for: round.length), mood: .excited, hop: true),
                    AnticStep(duration: 0.5, mood: .happy, glyph: .notes)], at: stage.date)))
            case .light(let rune, _):
                sound.rune(rune)
                haptics.rune(rune)
                burst(at: center(rune), rune: rune, count: stage.calm ? 6 : 14)
                if voiceOver { AccessibilityNotification.Announcement(EchoArt.names[rune]).post() }
            case .yourTurn:
                outcome = .none
                haptics.yourTurn()
                AccessibilityNotification.Announcement(String(localized: "Your turn")).post()
            case .tapped(let rune, _):
                sound.rune(rune)
                haptics.rune(rune)
                burst(at: center(rune), rune: rune, count: stage.calm ? 6 : 12)
                if !lesson { popups.append(Popup(text: "+1", pos: CGPoint(x: center(rune).x, y: center(rune).y - 62), color: EchoArt.colors[rune])) }
                // The closest Imp hops over to join in.
                if let id = nearest(to: stand(rune, slot: 1), stage) {
                    leap(id, to: rune, duration: 0.22, stage: stage)
                    out.cues.append(Cue(id: id, performance: Performance(key: "echo", steps: [
                        AnticStep(duration: 0.22, mood: .excited, hop: true),
                        AnticStep(duration: 0.4, mood: .happy)], at: stage.date)))
                }
            case .cleared(_, let points, let clean, let streak, let gained):
                outcome = .cleared
                sound.cleared()
                haptics.cleared(clean: clean)
                let mid = CGPoint(x: field.midX, y: field.midY)
                if lesson {
                    popups.append(Popup(text: String(localized: "Nice!"), pos: mid, color: Dungeon.flame, big: true))
                } else {
                    let text = clean ? String(localized: "Clean! +\(points)") : "+\(points)"
                    popups.append(Popup(text: text, pos: mid, color: clean ? Dungeon.flame : Dungeon.cream, big: true))
                    if gained {
                        popups.append(Popup(text: String(localized: "A life back!"), pos: CGPoint(x: mid.x, y: mid.y + 36), color: SparkArt.chain, big: true))
                    }
                    AccessibilityNotification.Announcement(clean ? String(localized: "Clean. \(points) points") : String(localized: "\(points) points")).post()
                }
                for (i, id) in stage.ids.enumerated() {
                    out.cues.append(Cue(id: id, performance: cheer(delay: 0.1 * Double(i), clean: clean, streak: streak, date: stage.date)))
                }
                burstAll(count: stage.calm ? 10 : 26)
            case .mistake(let rune, _, let left):
                outcome = .slipped
                sound.mistake()
                haptics.mistake()
                popups.append(Popup(text: lesson ? String(localized: "Not quite") : String(localized: "Oops!"),
                                    pos: CGPoint(x: center(rune).x, y: center(rune).y - 62), color: SparkArt.smokeEdge, big: true))
                for id in stage.ids {
                    out.cues.append(lesson
                        ? Cue(id: id, performance: Performance(key: "echo", steps: [
                            AnticStep(duration: 1.0, mood: .surprised, glyph: .question)], at: stage.date))
                        : Cue(id: id, performance: Performance(key: "echo", steps: [
                            AnticStep(duration: 0.9, mood: .dizzy, glyph: .sweat, move: BodyMove(kind: .wobble, times: 2)),
                            AnticStep(duration: 0.6, mood: .annoyed)], at: stage.date), dizzy: 1.2))
                }
                AccessibilityNotification.Announcement(lesson ? String(localized: "Not quite. Watch again")
                    : left > 0 ? String(localized: "Wrong rune. \(left) lives left") : String(localized: "Wrong rune")).post()
            case .hint(let rune):
                game.tick(1)
                AccessibilityNotification.Announcement(String(localized: "Try the \(EchoArt.names[rune]) rune")).post()
            case .rules:
                outcome = .none
            case .countdown:
                UserDefaults.standard.set(true, forKey: StageEngine.echoTutorialKey)
            case .tick(let n):
                game.tick(n)
            case .finished:
                finish(stage: stage, out: &out)
            }
        }
    }

    private func finish(stage: Stage, out: inout Output) {
        let score = round.score
        let isBest = score > best
        if isBest { UserDefaults.standard.set(score, forKey: Self.bestKey) }
        round.isRecord = isBest
        game.finished(best: isBest)
        for (i, id) in stage.ids.enumerated() {
            let steps: [AnticStep]
            let delay = 0.1 * Double(i)
            if round.completed {
                steps = [AnticStep(duration: delay + 0.1, mood: .excited),
                         AnticStep(duration: 1.2, mood: .excited, glyph: .sparkles, hop: true, move: BodyMove(kind: .spin)),
                         AnticStep(duration: 0.8, mood: .happy, glyph: .heart)]
            } else if score > 0 {
                steps = [AnticStep(duration: delay + 0.1, mood: .content),
                         AnticStep(duration: 1.0, mood: .happy, glyph: .heart, hop: true)]
            } else {
                steps = [AnticStep(duration: delay + 0.1, mood: .content),
                         AnticStep(duration: 1.0, mood: .shy)]
            }
            out.cues.append(Cue(id: id, performance: Performance(key: "echo", steps: steps, at: stage.date)))
        }
        let points = score
        AccessibilityNotification.Announcement(round.completed ? String(localized: "Perfect echo! \(points) points")
            : isBest ? String(localized: "Echo over. \(points) points. New best!") : String(localized: "Echo over. \(points) points")).post()
    }

    /// A happy dance; a clean one is bigger, and a streak spins.
    private func cheer(delay: Double, clean: Bool, streak: Int, date: Date) -> Performance {
        var steps: [AnticStep] = []
        if delay > 0 { steps.append(AnticStep(duration: delay, mood: .happy)) }
        if clean {
            steps.append(AnticStep(duration: 1.0, mood: .excited, glyph: streak >= 3 ? .sparkles : .heart, hop: true,
                                   move: streak >= 3 ? BodyMove(kind: .spin) : nil))
        } else {
            steps.append(AnticStep(duration: 0.9, mood: .happy, glyph: .heart, hop: true))
        }
        steps.append(AnticStep(duration: 0.4, mood: .happy))
        return Performance(key: "echo", steps: steps, at: date)
    }

    // MARK: Hops

    /// The next Imp to take a turn: the ones not already in the air first.
    private func pick(_ stage: Stage) -> UUID? {
        let free = stage.ids.filter { leaps[$0] == nil }
        let pool = free.isEmpty ? stage.ids : free
        guard !pool.isEmpty else { return nil }
        turn += 1
        return pool[turn % pool.count]
    }

    private func nearest(to point: CGPoint, _ stage: Stage) -> UUID? {
        stage.ids.filter { leaps[$0] == nil }.min {
            let a = stage.positions[$0] ?? point, b = stage.positions[$1] ?? point
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }
    }

    private func leap(_ id: UUID, to rune: Int, duration: Double, stage: Stage) {
        let slot = stage.ids.firstIndex(of: id) ?? 0
        let from = stage.positions[id] ?? stand(rune, slot: slot)
        leaps[id] = Leap(from: from, to: stand(rune, slot: slot), start: clock, duration: max(0.1, duration))
    }

    /// Imps in the air follow their arc to the rune.
    private func move(_ dt: Double, stage: Stage, out: inout Output) {
        let arc = stage.calm ? 14.0 : 44.0
        for (id, leap) in leaps {
            guard stage.ids.contains(id) else { leaps[id] = nil; continue }
            let t = min(1, max(0, (clock - leap.start) / leap.duration))
            let e = t * t * (3 - 2 * t)
            out.places[id] = CGPoint(x: leap.from.x + (leap.to.x - leap.from.x) * e,
                                     y: leap.from.y + (leap.to.y - leap.from.y) * e - arc * 4 * t * (1 - t))
            if t >= 1 { leaps[id] = nil }
        }
        for i in popups.indices { popups[i].age += dt }
        popups.removeAll { $0.age >= $0.life }
        for i in sparks.indices {
            sparks[i].age += dt
            let k = exp(-3 * dt)
            sparks[i].vel = CGVector(dx: sparks[i].vel.dx * k, dy: sparks[i].vel.dy * k)
            sparks[i].pos.x += sparks[i].vel.dx * dt
            sparks[i].pos.y += sparks[i].vel.dy * dt
        }
        sparks.removeAll { $0.age >= $0.life }
    }

    // MARK: Sparks

    private func burst(at p: CGPoint, rune: Int, count: Int) {
        for _ in 0..<count where sparks.count < 90 {
            let angle = Double.random(in: 0..<(2 * .pi)), v = Double.random(in: 60...220)
            sparks.append(Spark(pos: p, vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v), rune: rune,
                                radius: Double.random(in: 1.6...3.2), life: Double.random(in: 0.4...0.8)))
        }
    }

    /// A shower from the middle in every rune's colour.
    private func burstAll(count: Int) {
        for i in 0..<count where sparks.count < 90 {
            let angle = Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05), v = Double.random(in: 160...380)
            sparks.append(Spark(pos: CGPoint(x: field.midX, y: field.midY),
                                vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v), rune: i % EchoRound.runes,
                                radius: Double.random(in: 1.8...3.4), life: Double.random(in: 0.6...1.1)))
        }
    }
}
