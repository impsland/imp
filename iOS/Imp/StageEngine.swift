import ImpKit
import SwiftUI

/// The physics of the phone's stage: where each Imp is, how it moves while it floats free, is
/// dragged, thrown, or flies in. A plain class driven by the stage's timeline every frame (it is
/// deliberately not observable: the timeline redraws anyway, and mutating observed state while
/// a view body runs is a loop waiting to happen).
@MainActor
final class StageEngine {
    enum Phase: Equatable {
        /// Floating free: friction, soft bounces off the walls.
        case free
        case dragging
        /// Flying off a side. `toss`: throw it to the device its door leads to once it's gone
        /// (otherwise its home called it, or it just leaves).
        case flyingOut(toss: Bool)
        /// Out of sight, waiting for the other device to say yes (`leave`) or no (`refused`).
        case away
    }

    /// How an Imp leaves the screen: the way it went, and the device its door led to.
    struct Exit: Equatable {
        var side: LinkSide
        var height: Double
        /// Points a second (0: gently, from a menu).
        var speed: Double
        /// The device it is thrown to; nil when it just leaves.
        var to: UUID?
        /// Moving in for good on a Mac (`PocketRuntime.move`), not just visiting.
        var moves = false
    }

    struct Body {
        var imp: LinkImp
        var pos: CGPoint
        var vel = CGVector.zero
        var phase = Phase.free
        /// Friction (1/s): high while an arrival brakes, gentle afterwards.
        var drag = StageEngine.restDrag
        /// The side it came in from, until it's all the way inside (no wall there before).
        var enteringFrom: LinkSide?
        var lean = 0.0
        var performance: Performance?
        var dizzyUntil = Date.distantPast
        var floatPhase: Double
        /// Finger → centre while dragging.
        var grab = CGSize.zero
        var lastSample: (point: CGPoint, time: Date)?
        var fingerVelocity = CGVector.zero
        var warnedOffline = false
        var exit: Exit?
        var size: CGFloat { StageEngine.baseSize * imp.scale }
    }

    nonisolated static let baseSize: CGFloat = 112
    nonisolated static let restDrag = 2.4
    nonisolated static let bounce = 0.5
    /// During a round Imps keep their speed longer and bounce harder, so a throw is worth it.
    nonisolated static let gameDrag = 0.8
    nonisolated static let gameBounce = 0.85
    nonisolated static let maxCarry = 3_200.0

    private(set) var bodies: [UUID: Body] = [:]
    /// Back to front: whoever was touched last is on top.
    private(set) var order: [UUID] = []
    private(set) var size = CGSize(width: 393, height: 852)
    private var insets = EdgeInsets()
    private var last: Date?
    /// How fast the stage needs drawing (see `StagePacer`).
    let pacer = StagePacer()
    /// Where a finger is touching the screen, for the Imps to glance at.
    var touch: CGPoint?
    /// The Imp touched last (a jolt of the phone throws this one).
    private(set) var focus: UUID?

    /// The round of Embers being played (or just finished, until its card is dismissed).
    private(set) var round: GameRound?
    var reduceMotion = false
    private let haptics = GameHaptics()
    private let ticks = UISelectionFeedbackGenerator()
    /// The device whose door the carried Imp is in front of, if it is near enough to an edge.
    private(set) var litDoor: UUID?
    /// The round of Echo being played (or just finished, until its card is dismissed).
    private(set) var echo: EchoSession?
    /// A game is being played: Imps keep their speed and bounce harder (physics only).
    var isPlaying: Bool { echo != nil || (round.map { !$0.isOver } ?? false) }
    /// A game's card is up, from the lesson to the card of the result: edges always bounce, nobody
    /// can be tossed or passed in or out, and a tap on an Imp opens no chat.
    var isBlocking: Bool { round != nil || echo != nil }

    /// Whether any device is connected to throw Imps to.
    var isConnected: () -> Bool = { true }
    /// Where an Imp thrown off a side at a height goes (see `LinkDoors`).
    var door: (UUID, LinkSide, Double) -> LinkDoors.Outcome = { _, _, _ in .bounce(.nobodyConnected) }
    /// The side (the given one first) and height an Imp leaves by to reach a device, if a door leads there.
    var way: (UUID, UUID, LinkSide) -> (side: LinkSide, height: Double)? = { _, _, _ in nil }
    /// The doors on a side for an Imp, to label while it is carried (see `DoorLabels`).
    var doors: (UUID, LinkSide) -> [LinkHub.DoorLabel] = { _, _ in [] }
    /// What to say when an Imp bounces off a side that leads nowhere.
    var hint: (UUID, LinkDoors.Bounce, LinkSide) -> String = { _, _, _ in "" }
    /// An Imp that was thrown has left the screen.
    var send: (UUID, Exit) -> Void = { _, _ in }
    var warn: (String) -> Void = { _ in }
    var felt: (UUID, LinkFeeling) -> Void = { _, _ in }

    // MARK: Roster

    /// Brings the bodies in line with the screen's list: new Imps appear at rest and Imps no longer
    /// listed go. One that is away waits for the other device's answer (`leave` or `refused`).
    func reconcile(_ imps: [LinkImp]) {
        let ids = Set(imps.map(\.id))
        for id in order where !ids.contains(id) {
            if case .away = bodies[id]?.phase { continue }
            remove(id)
        }
        for (n, imp) in imps.enumerated() {
            if var body = bodies[imp.id] {
                body.imp = imp
                bodies[imp.id] = body
            } else {
                var b = Body(imp: imp, pos: restingSpot(n), floatPhase: Double(n) * 1.7)
                b.phase = .free
                insert(b)
            }
        }
    }

    private func restingSpot(_ n: Int) -> CGPoint {
        let f = field
        let x = n % 2 == 0 ? f.minX + f.width * 0.32 : f.minX + f.width * 0.68
        return CGPoint(x: x, y: f.minY + f.height * (0.3 + 0.18 * Double(n % 4)))
    }

    private func insert(_ b: Body) {
        bodies[b.imp.id] = b
        order.removeAll { $0 == b.imp.id }
        order.append(b.imp.id)
        pacer.wake()
    }

    private func remove(_ id: UUID) {
        bodies[id] = nil
        order.removeAll { $0 == id }
        if focus == id { focus = nil }
        if order.isEmpty { round = nil; endEcho() }
    }

    // MARK: Events from other devices

    func arrive(_ imp: LinkImp, _ entry: LinkEntry) {
        let r = StageEngine.baseSize * imp.scale / 2
        let f = field
        let speed = min(max(entry.speed, 900), 2_600)
        let y = min(max(entry.height * size.height, f.minY + r), f.maxY - r)
        let from: CGFloat = entry.side == .left ? -r * 1.15 : size.width + r * 1.15
        var b = Body(imp: imp, pos: CGPoint(x: from, y: y), floatPhase: Double.random(in: 0...6))
        // Brake so it coasts to a stop a good way in: the harder the throw, the further it lands.
        let t = (speed - 900) / 1_700
        let travel = size.width * (0.45 + 0.25 * t)
        b.drag = speed / travel
        b.vel = CGVector(dx: entry.side == .left ? speed : -speed, dy: (f.midY - y) * 0.6)
        b.enteringFrom = entry.side
        b.performance = Performance(key: "arrive", steps: Self.arrivalSteps)
        insert(b)
    }

    /// Surprised by the flight, then happy to have landed.
    private static let arrivalSteps = [
        AnticStep(duration: 0.9, mood: .surprised, glyph: .exclaim),
        AnticStep(duration: Motion.hopLength, mood: .happy, hop: true),
        AnticStep(duration: 0.9, mood: .happy),
    ]

    func leave(_ id: UUID) {
        guard var b = bodies[id] else { return }
        if case .away = b.phase { remove(id); return }
        let side: LinkSide = b.pos.x < size.width / 2 ? .left : .right
        fly(&b, side: side, speed: 1_300, to: nil)
        bodies[id] = b
    }

    func refused(_ id: UUID, _ reason: String) {
        warn(reason)
        guard var b = bodies[id] else { return }
        switch b.phase {
        case .away:
            comeBack(&b, note: reason)
        case .flyingOut:
            // Still on its way out (and in sight): it turns around instead of coming in anew.
            b.phase = .free
            b.drag = 4.5
            b.vel = CGVector(dx: -b.vel.dx * 0.3, dy: b.vel.dy * 0.3)
            b.enteringFrom = nil
            b.performance = Performance(key: "bounce", steps: [AnticStep(duration: 0.8, mood: .sad, glyph: .sweat),
                                                               AnticStep(duration: 0.6, mood: .content)])
        default:
            break
        }
        bodies[id] = b
    }

    func animate(_ id: UUID, _ beats: [AnimationBeat]) {
        guard bodies[id] != nil, !beats.isEmpty else { return }
        pacer.wake()
        bodies[id]?.performance = Performance(key: "mac", steps: beats.map(AnticStep.init))
    }

    /// Back in from the side it left by.
    private func comeBack(_ b: inout Body, note: String?) {
        let side = b.exit?.side ?? .right
        let r = b.size / 2
        let y = min(max((b.exit?.height ?? 0.5) * size.height, field.minY + r), field.maxY - r)
        b.pos = CGPoint(x: side == .left ? -r * 1.15 : size.width + r * 1.15, y: y)
        b.vel = CGVector(dx: side == .left ? 1_100 : -1_100, dy: 0)
        b.drag = 4.5
        b.enteringFrom = side
        b.phase = .free
        b.performance = Performance(key: "bounce", steps: [AnticStep(duration: 0.8, mood: .sad, glyph: .sweat),
                                                           AnticStep(duration: 0.6, mood: .content)])
    }

    // MARK: Throwing

    private func fly(_ b: inout Body, side: LinkSide, speed: Double, to device: UUID?, moves: Bool = false, vy: Double = 0) {
        pacer.wake()
        b.phase = .flyingOut(toss: device != nil)
        b.enteringFrom = nil
        b.drag = 0
        let v = max(speed, 1_100)
        b.vel = CGVector(dx: side == .left ? -v : v, dy: vy * 0.5)
        b.exit = Exit(side: side, height: min(max(Double(b.pos.y / max(1, size.height)), 0), 1), speed: device == nil ? 0 : speed,
                      to: device, moves: moves)
        b.performance = Performance(key: "thrown", steps: [AnticStep(duration: 1.5, mood: .excited, move: nil)])
    }

    /// The height of an Imp on the screen: 0 the top, 1 the bottom.
    private func height(of b: Body) -> Double { min(max(Double(b.pos.y / max(1, size.height)), 0), 1) }

    /// How far from the edge an Imp's door labels start to show, and where they are fully shown.
    nonisolated static let doorReach: CGFloat = 150
    nonisolated static let doorNear: CGFloat = 60

    /// The Imp in a hand, if any (and no game is on).
    var carried: Body? { isBlocking ? nil : order.lazy.compactMap { self.bodies[$0] }.first { $0.phase == .dragging } }

    /// The side a carried Imp is nearer to and how close it is to it: 0 out of reach, 1 at the door.
    func nearness(of b: Body) -> (side: LinkSide, amount: Double) {
        let left = b.pos.x < size.width / 2
        let distance = left ? b.pos.x : size.width - b.pos.x
        let amount = (Self.doorReach - distance) / (Self.doorReach - Self.doorNear)
        return (left ? .left : .right, min(max(Double(amount), 0), 1))
    }

    /// Keeps `litDoor` to the door under the finger, with a tick each time it changes to another.
    private func light(_ b: Body) {
        var lit: UUID?
        let near = nearness(of: b)
        if !isBlocking, near.amount > 0.5, case .to(let device) = door(b.imp.id, near.side, height(of: b)) { lit = device }
        guard lit != litDoor else { return }
        litDoor = lit
        if lit != nil { ticks.selectionChanged() }
    }

    /// Throws `id` off `side` to the device that side leads to at the Imp's height. A side that leads
    /// nowhere bounces it back with a hint (once, until it is picked up again).
    @discardableResult
    func toss(_ id: UUID, side: LinkSide, speed: Double, velocityY: Double = 0) -> Bool {
        // In a hand or free: one that is already on its way out (or away) isn't thrown a second time.
        guard !isBlocking, var b = bodies[id], b.phase == .free || b.phase == .dragging else { return false }
        switch door(id, side, height(of: b)) {
        case .bounce(let why):
            if !b.warnedOffline { warn(hint(id, why, side)) }
            b.warnedOffline = true
            bodies[id] = b
            return false
        case .to(let device):
            fly(&b, side: side, speed: speed, to: device, vy: velocityY)
            bodies[id] = b
            return true
        }
    }

    /// Send to a device from the menu: a gentle push off the nearer side that leads there (speed 0).
    /// `moves`: it moves in for good on a Mac (`PocketRuntime.move`), not just visiting.
    func sendGently(_ id: UUID, to device: UUID, moves: Bool = false) {
        guard !isBlocking, var b = bodies[id], b.phase == .free else { return }
        let nearer: LinkSide = b.pos.x < size.width / 2 ? .left : .right
        guard let way = way(id, device, nearer) else { return warn(hint(id, .nobodyConnected, nearer)) }
        fly(&b, side: way.side, speed: 0, to: device, moves: moves)
        // Drifts towards the height of its door on the way out.
        let reach = way.side == .left ? b.pos.x + b.size / 2 : size.width - b.pos.x + b.size / 2
        let dy = (way.height * size.height - b.pos.y) * 700 / max(1, reach)
        b.vel = CGVector(dx: way.side == .left ? -700 : 700, dy: dy)
        bodies[id] = b
    }

    /// A sharp jolt of the whole phone: the focused Imp (or the only one) is thrown off that side.
    func jolt(_ side: LinkSide) {
        guard let id = focus ?? (order.count == 1 ? order.first : nil), let b = bodies[id], b.phase == .free else { return }
        toss(id, side: side, speed: 1_800)
    }

    /// A shake: everyone gets dizzy.
    func shake(now: Date = Date()) {
        for id in order where bodies[id]?.phase == .free {
            bodies[id]?.dizzyUntil = now.addingTimeInterval(3.2)
            felt(id, .shake)
        }
    }

    // MARK: Embers

    nonisolated static let tutorialKey = "embersTutorialSeen"

    /// Starts a round, if there is anyone to play with. The first one (or one asked for) begins with the lesson.
    func startGame(tutorial: Bool = false) {
        guard !order.isEmpty, echo == nil else { return }
        pacer.wake()
        let coaching = tutorial || !UserDefaults.standard.bool(forKey: Self.tutorialKey)
        round = GameRound(coaching: coaching)
        haptics.prepare()
        if coaching { AccessibilityNotification.Announcement(GameRound.caption).post() }
    }

    /// Dismisses the finished round's card.
    func endGame() { round = nil }

    /// Moves the lesson on: from the line or the rules to the countdown.
    func skipLesson(now: Date = Date()) {
        guard var round else { return }
        let events = round.nextStep()
        handle(events, in: &round, at: now)
        self.round = round
    }

    var best: Int { UserDefaults.standard.integer(forKey: "emberBest") }

    /// Keeps the best, and says whether this round beat it.
    private func finishGame(_ round: inout GameRound) -> Bool {
        let defaults = UserDefaults.standard
        let isBest = round.score > best
        if isBest { defaults.set(round.score, forKey: "emberBest") }
        // Clean rounds in a row, and rounds where nothing got away.
        round.cleanStreak = round.cleanBurn ? defaults.integer(forKey: "emberCleanStreak") + 1 : 0
        defaults.set(round.cleanStreak, forKey: "emberCleanStreak")
        round.flawlessRounds = defaults.integer(forKey: "emberFlawless") + (round.flawless ? 1 : 0)
        defaults.set(round.flawlessRounds, forKey: "emberFlawless")
        haptics.finished(best: isBest)
        let points = round.score
        var words = [isBest ? String(localized: "Time. \(points) points. New best!") : String(localized: "Time. \(points) points")]
        if round.flawless { words.append(String(localized: "Nothing got away.")) }
        if round.cleanBurn { words.append(String(localized: "Clean burn.")) }
        AccessibilityNotification.Announcement(words.joined(separator: " ")).post()
        return isBest
    }

    /// How an Imp looks while playing: nil outside a round.
    func gameMood(_ b: Body, at date: Date) -> Mood? {
        guard isPlaying else { return nil }
        if let echo { return echo.mood(of: b.imp.id, dizzy: b.dizzyUntil > date) }
        if b.dizzyUntil > date { return .dizzy }
        if b.phase == .dragging { return .curious }
        return hypot(b.vel.dx, b.vel.dy) > GameRound.flightSpeed ? .excited : .idle
    }

    private func play(_ dt: Double, date: Date) {
        if echo != nil { return playEcho(dt, date: date) }
        guard var round else { return }
        if round.isOver {
            round.settle(dt, in: field, calm: reduceMotion)
            self.round = round
            return
        }
        if let guide = round.guide, bodies[guide.id] == nil { round.dropGuide() }
        let ids = order.filter { bodies[$0]?.phase == .free && bodies[$0]?.enteringFrom == nil }
        var movers = ids.compactMap { id in
            bodies[id].map { GameRound.Mover(id: id, pos: $0.pos, vel: $0.vel, radius: $0.size * 0.36) }
        }
        let events = round.advance(dt, in: field, movers: &movers, calm: reduceMotion)
        for m in movers {
            bodies[m.id]?.pos = m.pos
            bodies[m.id]?.vel = m.vel
        }
        handle(events, in: &round, at: date)
        self.round = round
    }

    private func handle(_ events: [GameRound.Event], in round: inout GameRound, at date: Date) {
        for event in events {
            switch event {
            case .caught(let id, _, let multiplier):
                bodies[id]?.performance = Performance(key: "catch", steps: [
                    AnticStep(duration: 0.6, mood: .excited, glyph: multiplier > 2 ? .heart : nil, hop: true)])
                haptics.caught(multiplier)
            case .kindled(let id):
                bodies[id]?.performance = Performance(key: "catch", steps: [AnticStep(duration: 0.7, mood: .happy, glyph: .heart, hop: true)])
                haptics.kindled()
            case .smoked(let id):
                bodies[id]?.dizzyUntil = date.addingTimeInterval(1.1)
                bodies[id]?.performance = Performance(key: "smoke", steps: [
                    AnticStep(duration: 0.9, mood: .dizzy, glyph: .sweat),
                    AnticStep(duration: 0.7, mood: .annoyed)])
                haptics.smoked()
            case .cheered(let id):
                bodies[id]?.performance = Performance(key: "catch", steps: [AnticStep(duration: 0.9, mood: .excited, glyph: .heart, hop: true)])
            case .bonk(let a, let b):
                for id in [a, b] {
                    bodies[id]?.dizzyUntil = date.addingTimeInterval(1.6)
                    bodies[id]?.performance = nil
                }
                haptics.bonk()
            case .blaze:
                haptics.blaze()
                AccessibilityNotification.Announcement(String(localized: "Blaze. Points count double")).post()
            case .perfectWave(let id, let streak, _):
                haptics.perfect(streak)
                if let id {
                    bodies[id]?.performance = Performance(key: "catch", steps: [
                        AnticStep(duration: 0.8, mood: .happy, glyph: .sparkles, hop: true)])
                }
            case .ring(let id, _):
                haptics.ring()
                if let id {
                    bodies[id]?.performance = Performance(key: "catch", steps: [
                        AnticStep(duration: 1.1, mood: .excited, glyph: .sparkles, hop: true, move: BodyMove(kind: .spin))])
                }
            case .special(let kind):
                haptics.phase()
                AccessibilityNotification.Announcement("\(kind.title) \(kind.hint)").post()
            case .specialEnded:
                break
            case .cleanBurn:
                haptics.cleanBurn()
                celebrate(glyph: .sparkles, move: nil, at: date)
            case .flawless:
                haptics.flawless()
                celebrate(glyph: .heart, move: BodyMove(kind: .spin), at: date)
            case .countdown:
                UserDefaults.standard.set(true, forKey: Self.tutorialKey)
            case .tick(let n):
                haptics.tick(n)
            case .finished:
                round.isRecord = finishGame(&round)
            }
        }
    }

    /// Every Imp takes a turn at a little dance, one after the other.
    private func celebrate(glyph: Glyph, move: BodyMove?, at date: Date) {
        for (i, id) in order.enumerated() where bodies[id]?.phase == .free {
            bodies[id]?.performance = Performance(key: "catch", steps: [
                AnticStep(duration: 0.12 * Double(i) + 0.05, mood: .happy),
                AnticStep(duration: 1.2, mood: .excited, glyph: glyph, hop: true, move: move),
                AnticStep(duration: 0.6, mood: .happy)], at: date)
        }
    }

    // MARK: Echo

    nonisolated static let echoTutorialKey = "echoTutorialSeen"

    /// Starts a round of Echo, if there is anyone to play with and Embers isn't on. The first one
    /// (or one asked for) begins with the guided step.
    func startEcho(tutorial: Bool = false) {
        guard !order.isEmpty, round == nil else { return }
        echo?.close()
        let coaching = tutorial || !UserDefaults.standard.bool(forKey: Self.echoTutorialKey)
        // Whoever is in a hand is put down, and everyone settles.
        for id in order where bodies[id]?.phase == .dragging { bodies[id]?.phase = .free; bodies[id]?.vel = .zero }
        echo = EchoSession(coaching: coaching)
        pacer.wake()
    }

    /// Dismisses Echo (and its card).
    func endEcho() {
        echo?.close()
        echo = nil
    }

    /// The player is done: the round ends with what it earned.
    func stopEcho(now: Date = Date()) {
        guard let echo else { return }
        apply(echo.stop(in: field, stage: echoStage(now)), now: now)
    }

    /// Moves the guided step on: to the countdown.
    func skipEchoLesson(now: Date = Date()) {
        guard let echo else { return }
        apply(echo.skip(in: field, stage: echoStage(now)), now: now)
    }

    /// The player taps rune `rune`.
    func tapRune(_ rune: Int, now: Date = Date()) {
        guard let echo else { return }
        apply(echo.tap(rune, in: field, stage: echoStage(now)), now: now)
    }

    private func echoStage(_ date: Date) -> EchoSession.Stage {
        let ids = order.filter { bodies[$0]?.phase == .free && bodies[$0]?.enteringFrom == nil }
        return EchoSession.Stage(ids: ids, positions: Dictionary(uniqueKeysWithValues: ids.compactMap { id in bodies[id].map { (id, $0.pos) } }),
                                 date: date, calm: reduceMotion)
    }

    private func playEcho(_ dt: Double, date: Date) {
        guard let echo else { return }
        let stage = echoStage(date)
        // Nobody drifts: whatever speed an Imp had when the game began dies away.
        for id in stage.ids { if let v = bodies[id]?.vel { let k = exp(-8 * dt); bodies[id]?.vel = CGVector(dx: v.dx * k, dy: v.dy * k) } }
        apply(echo.advance(dt, in: field, stage: stage), now: date)
    }

    /// Puts the Imps where the game wants them and has them act.
    private func apply(_ out: EchoSession.Output, now: Date) {
        for (id, p) in out.places {
            bodies[id]?.pos = p
            bodies[id]?.vel = .zero
        }
        for cue in out.cues {
            bodies[cue.id]?.performance = cue.performance
            if cue.dizzy > 0 { bodies[cue.id]?.dizzyUntil = now.addingTimeInterval(cue.dizzy) }
        }
    }

    // MARK: Fingers

    func dragChanged(_ id: UUID, at p: CGPoint, now: Date = Date()) {
        guard var b = bodies[id] else { return }
        // In Echo the Imps stand on the runes: nobody is picked up.
        if echo != nil, b.phase != .dragging { return }
        touch = p
        switch b.phase {
        case .free:
            b.phase = .dragging
            b.grab = CGSize(width: b.pos.x - p.x, height: b.pos.y - p.y)
            b.vel = .zero
            b.enteringFrom = nil
            b.lastSample = nil
            b.fingerVelocity = .zero
            b.warnedOffline = false
            b.performance = nil
            focus = id
            ticks.prepare()
            pacer.wake()
            order.removeAll { $0 == id }
            order.append(id)
        case .dragging: break
        default: return
        }
        if let s = b.lastSample {
            let dt = max(now.timeIntervalSince(s.time), 1 / 240)
            let v = CGVector(dx: (p.x - s.point.x) / dt, dy: (p.y - s.point.y) / dt)
            // Smoothed: a single odd sample must not become a throw.
            b.fingerVelocity = CGVector(dx: b.fingerVelocity.dx * 0.5 + v.dx * 0.5, dy: b.fingerVelocity.dy * 0.5 + v.dy * 0.5)
        }
        b.lastSample = (p, now)
        let r = b.size / 2
        b.pos = CGPoint(x: min(max(p.x + b.grab.width, -r), size.width + r),
                        y: min(max(p.y + b.grab.height, field.minY), field.maxY))
        bodies[id] = b
        light(b)
        if let out = Toss.phoneExit(point: p, velocity: b.fingerVelocity, bounds: size) {
            toss(id, side: out.side, speed: abs(b.fingerVelocity.dx), velocityY: b.fingerVelocity.dy)
        }
    }

    func dragEnded(_ id: UUID, at p: CGPoint, predicted: CGPoint, now: Date = Date()) {
        touch = nil
        litDoor = nil
        guard var b = bodies[id], b.phase == .dragging else { return }
        // Stopped before letting go: no momentum.
        if let s = b.lastSample, now.timeIntervalSince(s.time) > 0.08 { b.fingerVelocity = .zero }
        let v = b.fingerVelocity
        bodies[id] = b
        if let out = Toss.phoneRelease(point: p, predicted: predicted, velocity: v, bounds: size),
           toss(id, side: out.side, speed: abs(v.dx), velocityY: v.dy) {
            return
        }
        let speed = hypot(v.dx, v.dy)
        let k = speed > Self.maxCarry ? Self.maxCarry / speed : 1
        bodies[id]?.vel = CGVector(dx: v.dx * k, dy: v.dy * k)
        bodies[id]?.phase = .free
        bodies[id]?.drag = Self.restDrag
    }

    // MARK: Frames

    /// The area an Imp's centre may float in (below the status pill, above the home indicator).
    private var field: CGRect {
        CGRect(x: 0, y: insets.top + 70, width: size.width, height: max(100, size.height - insets.top - insets.bottom - 70 - 40))
    }

    /// Advances the world to `date`. Called by the timeline once a frame.
    func step(_ date: Date, size: CGSize, insets: EdgeInsets) {
        self.size = size
        self.insets = insets
        let dt = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 1 / 30)
        last = date
        guard dt > 0 else { return }
        let f = field
        for id in order {
            guard var b = bodies[id] else { continue }
            let r = b.size / 2
            switch b.phase {
            case .dragging:
                // A finger that stops stops its speed too.
                if let s = b.lastSample, date.timeIntervalSince(s.time) > 0.05 {
                    let k = exp(-10 * dt)
                    b.fingerVelocity = CGVector(dx: b.fingerVelocity.dx * k, dy: b.fingerVelocity.dy * k)
                }
                b.lean += (Self.lean(b.fingerVelocity.dx) - b.lean) * min(1, dt * 10)
            case .free:
                let k = exp(-(isPlaying && b.enteringFrom == nil ? Self.gameDrag : b.drag) * dt)
                b.vel = CGVector(dx: b.vel.dx * k, dy: b.vel.dy * k)
                if let side = b.enteringFrom {
                    // Still on its way in: nothing stops it at the side it came through, and it
                    // never stalls outside.
                    let inward: Double = side == .left ? 1 : -1
                    if b.vel.dx * inward < 260 { b.vel.dx = inward * 260 }
                }
                b.pos.x += b.vel.dx * dt
                b.pos.y += b.vel.dy * dt
                collide(&b, r: r, field: f)
                if hypot(b.vel.dx, b.vel.dy) < 8, b.enteringFrom == nil { b.vel = .zero }
                if b.enteringFrom == nil, b.drag != Self.restDrag, hypot(b.vel.dx, b.vel.dy) < 120 { b.drag = Self.restDrag }
                b.lean += (Self.lean(b.vel.dx) - b.lean) * min(1, dt * 8)
            case .flyingOut(let toss):
                b.pos.x += b.vel.dx * dt
                b.pos.y += b.vel.dy * dt
                b.lean += (Self.lean(b.vel.dx) - b.lean) * min(1, dt * 10)
                if b.pos.x < -r * 1.2 || b.pos.x > size.width + r * 1.2 {
                    if toss, var exit = b.exit {
                        // The height it really left at: a throw can carry it up or down on the way out.
                        exit.height = height(of: b)
                        b.exit = exit
                        b.phase = .away
                        // Written back first: a toss that is refused at once (`refused`) must
                        // find the Imp away, and what it does to the body has to stay.
                        bodies[id] = b
                        send(id, exit)
                        continue
                    } else {
                        remove(id)
                        continue
                    }
                }
            case .away:
                // The other device's answer (or its silence) arrives as `leave` or `refused`.
                break
            }
            bodies[id] = b
        }
        play(dt, date: date)
        separate(dt)
        pacer.settle(moving: isMoving(at: date), empty: order.isEmpty && round == nil, at: date)
    }

    static func lean(_ vx: Double) -> Double { max(-14, min(14, vx * 0.012)) }

    /// Soft bounces off the walls. Coming in through a side, that side doesn't count until it's inside.
    private func collide(_ b: inout Body, r: CGFloat, field f: CGRect) {
        let bounce = isPlaying ? Self.gameBounce : Self.bounce
        let minX = r * 0.6, maxX = size.width - r * 0.6
        if b.pos.x < minX {
            if b.enteringFrom != .left { b.pos.x = minX; b.vel.dx = abs(b.vel.dx) * bounce }
        } else if b.pos.x > maxX {
            if b.enteringFrom != .right { b.pos.x = maxX; b.vel.dx = -abs(b.vel.dx) * bounce }
        } else if b.enteringFrom != nil {
            b.enteringFrom = nil
        }
        if b.pos.y < f.minY + r * 0.2 { b.pos.y = f.minY + r * 0.2; b.vel.dy = abs(b.vel.dy) * bounce }
        if b.pos.y > f.maxY - r * 0.7 { b.pos.y = f.maxY - r * 0.7; b.vel.dy = -abs(b.vel.dy) * bounce }
    }

    /// Imps are soft, not ghosts: two that overlap drift apart.
    private func separate(_ dt: Double) {
        let ids = order.filter { bodies[$0]?.phase == .free && bodies[$0]?.enteringFrom == nil }
        guard ids.count > 1 else { return }
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                guard var a = bodies[ids[i]], var c = bodies[ids[j]] else { continue }
                let dx = c.pos.x - a.pos.x, dy = c.pos.y - a.pos.y
                let d = max(1, hypot(dx, dy))
                let reach = (a.size + c.size) * 0.34
                guard d < reach else { continue }
                let push = (reach - d) * 6 * dt
                pacer.separating = true
                let ux = dx / d, uy = dy / d
                a.pos.x -= ux * push; a.pos.y -= uy * push
                c.pos.x += ux * push; c.pos.y += uy * push
                bodies[ids[i]] = a; bodies[ids[j]] = c
            }
        }
    }

    // MARK: Drawing helpers

    /// Where `b` is drawn: its place plus a gentle float (still while carried, calmer when asleep).
    func floatOffset(_ b: Body, at date: Date, calm: Bool) -> CGFloat {
        guard b.phase != .dragging else { return 0 }
        let t = date.timeIntervalSinceReferenceDate
        return CGFloat(sin(t * 1.5 + b.floatPhase) * (calm ? 1.5 : 3.5))
    }

    /// What `b` looks at: the finger if one is down, otherwise the closest friend.
    func gaze(for b: Body) -> (point: CGPoint, attentive: Bool)? {
        if let touch { return (touch, false) }
        var near: CGPoint?
        var nearest = CGFloat.infinity
        for id in order where id != b.imp.id {
            guard let other = bodies[id], other.phase == .free else { continue }
            let d = hypot(other.pos.x - b.pos.x, other.pos.y - b.pos.y)
            if d < nearest { nearest = d; near = other.pos }
        }
        return near.map { ($0, true) }
    }
}
