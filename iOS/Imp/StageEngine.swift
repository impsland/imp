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
        /// Flying off a side. `toss`: tell the Mac once it's gone (otherwise the Mac called it, or it just leaves).
        case flyingOut(toss: Bool)
        /// Out of sight, waiting for the Mac to say yes (`leave`) or no (`refused`).
        case away(since: Date)
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
        var exit: (side: LinkSide, height: Double, speed: Double)?
        var size: CGFloat { StageEngine.baseSize * imp.scale }
    }

    nonisolated static let baseSize: CGFloat = 112
    nonisolated static let restDrag = 2.4
    nonisolated static let bounce = 0.5
    /// During a round Imps keep their speed longer and bounce harder, so a throw is worth it.
    nonisolated static let gameDrag = 0.8
    nonisolated static let gameBounce = 0.85
    nonisolated static let maxCarry = 3_200.0
    /// How long the Mac has to answer a toss.
    nonisolated static let tossTimeout: TimeInterval = 10

    private(set) var bodies: [UUID: Body] = [:]
    /// Back to front: whoever was touched last is on top.
    private(set) var order: [UUID] = []
    private(set) var size = CGSize(width: 393, height: 852)
    private var insets = EdgeInsets()
    private var last: Date?
    /// Where a finger is touching the screen, for the Imps to glance at.
    var touch: CGPoint?
    /// The Imp touched last (a jolt of the phone throws this one).
    private(set) var focus: UUID?

    /// The round of Embers being played (or just finished, until its card is dismissed).
    private(set) var round: GameRound?
    var reduceMotion = false
    private let haptics = GameHaptics()
    /// A round is on: edges always bounce and nobody can be tossed away.
    var isPlaying: Bool { round.map { !$0.isOver } ?? false }

    var isConnected: () -> Bool = { true }
    var send: (UUID, LinkSide, Double, Double) -> Void = { _, _, _, _ in }
    var warn: (String) -> Void = { _ in }
    var felt: (UUID, LinkFeeling) -> Void = { _, _ in }

    // MARK: Roster

    /// Brings the bodies in line with the Mac's list: new Imps appear at rest, Imps the Mac no
    /// longer lists go, and an Imp that was waiting for an answer and is still ours comes back.
    func reconcile(_ imps: [LinkImp]) {
        let ids = Set(imps.map(\.id))
        for id in order where !ids.contains(id) { remove(id) }
        for (n, imp) in imps.enumerated() {
            if var body = bodies[imp.id] {
                body.imp = imp
                if case .away = body.phase { comeBack(&body, note: nil) }
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
    }

    private func remove(_ id: UUID) {
        bodies[id] = nil
        order.removeAll { $0 == id }
        if focus == id { focus = nil }
        if order.isEmpty { round = nil }
    }

    // MARK: Events from the Mac

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
        fly(&b, side: side, speed: 1_300, toss: false)
        bodies[id] = b
    }

    func refused(_ id: UUID, _ reason: String) {
        warn(reason)
        guard var b = bodies[id] else { return }
        switch b.phase {
        case .away, .flyingOut: comeBack(&b, note: reason)
        default: break
        }
        bodies[id] = b
    }

    func animate(_ id: UUID, _ beats: [AnimationBeat]) {
        guard bodies[id] != nil, !beats.isEmpty else { return }
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

    private func fly(_ b: inout Body, side: LinkSide, speed: Double, toss: Bool, vy: Double = 0) {
        b.phase = .flyingOut(toss: toss)
        b.enteringFrom = nil
        b.drag = 0
        let v = max(speed, 1_100)
        b.vel = CGVector(dx: side == .left ? -v : v, dy: vy * 0.5)
        b.exit = (side, min(max(Double(b.pos.y / max(1, size.height)), 0), 1), toss ? speed : 0)
        b.performance = Performance(key: "thrown", steps: [AnticStep(duration: 1.5, mood: .excited, move: nil)])
    }

    /// Throws `id` off `side` towards the Mac, if the Mac is there to catch it.
    @discardableResult
    func toss(_ id: UUID, side: LinkSide, speed: Double, velocityY: Double = 0) -> Bool {
        guard !isPlaying, var b = bodies[id] else { return false }
        guard isConnected() else {
            if !b.warnedOffline { warn(String(localized: "Your Mac isn't around")) }
            b.warnedOffline = true
            bodies[id] = b
            return false
        }
        fly(&b, side: side, speed: speed, toss: true, vy: velocityY)
        bodies[id] = b
        return true
    }

    /// Send to Mac from the menu: a gentle push off the right side (speed 0 for the Mac).
    func sendGently(_ id: UUID) {
        guard !isPlaying else { return }
        guard isConnected() else { return warn(String(localized: "Your Mac isn't around")) }
        guard var b = bodies[id] else { return }
        fly(&b, side: .right, speed: 0, toss: true)
        b.vel = CGVector(dx: 700, dy: 0)
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

    /// Starts a round, if there is anyone to play with.
    func startGame() {
        guard !order.isEmpty else { return }
        round = GameRound()
        haptics.prepare()
    }

    /// Dismisses the finished round's card.
    func endGame() { round = nil }

    var best: Int { UserDefaults.standard.integer(forKey: "emberBest") }

    private func finishGame(_ round: GameRound) {
        let isBest = round.score > best
        if isBest { UserDefaults.standard.set(round.score, forKey: "emberBest") }
        haptics.finished()
        AccessibilityNotification.Announcement(String(localized: "Time. \(round.score) points")).post()
    }

    /// How an Imp looks while playing: nil outside a round.
    func gameMood(_ b: Body, at date: Date) -> Mood? {
        guard isPlaying else { return nil }
        if b.dizzyUntil > date { return .dizzy }
        if b.phase == .dragging { return .curious }
        return hypot(b.vel.dx, b.vel.dy) > GameRound.flightSpeed ? .excited : .idle
    }

    private func play(_ dt: Double, date: Date) {
        guard var round, !round.isOver else { return }
        let ids = order.filter { bodies[$0]?.phase == .free && bodies[$0]?.enteringFrom == nil }
        var movers = ids.compactMap { id in
            bodies[id].map { GameRound.Mover(id: id, pos: $0.pos, vel: $0.vel, radius: $0.size * 0.36) }
        }
        let events = round.advance(dt, in: field, movers: &movers, calm: reduceMotion)
        for m in movers {
            bodies[m.id]?.pos = m.pos
            bodies[m.id]?.vel = m.vel
        }
        for event in events {
            switch event {
            case .caught(let id, _, let multiplier):
                bodies[id]?.performance = Performance(key: "catch", steps: [
                    AnticStep(duration: 0.6, mood: .excited, glyph: multiplier > 2 ? .heart : nil, hop: true)])
                haptics.caught(multiplier)
            case .bonk(let a, let b):
                for id in [a, b] {
                    bodies[id]?.dizzyUntil = date.addingTimeInterval(1.6)
                    bodies[id]?.performance = nil
                }
                haptics.bonk()
            case .finished:
                finishGame(round)
            }
        }
        self.round = round
    }

    // MARK: Fingers

    func dragChanged(_ id: UUID, at p: CGPoint, now: Date = Date()) {
        guard var b = bodies[id] else { return }
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
        if let out = Toss.phoneExit(point: p, velocity: b.fingerVelocity, bounds: size) {
            toss(id, side: out.side, speed: abs(b.fingerVelocity.dx), velocityY: b.fingerVelocity.dy)
        }
    }

    func dragEnded(_ id: UUID, at p: CGPoint, predicted: CGPoint, now: Date = Date()) {
        touch = nil
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
                        exit.height = min(max(Double(b.pos.y / max(1, size.height)), 0), 1)
                        b.exit = exit
                        b.phase = .away(since: date)
                        send(id, exit.side, exit.height, exit.speed)
                    } else {
                        remove(id)
                        continue
                    }
                }
            case .away(let since):
                if date.timeIntervalSince(since) > Self.tossTimeout {
                    refused(id, String(localized: "Your Mac didn't answer"))
                    continue
                }
            }
            bodies[id] = b
        }
        play(dt, date: date)
        separate(dt)
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
        let friends = order.compactMap { bodies[$0] }.filter { $0.imp.id != b.imp.id && $0.phase == .free }
        guard let near = friends.min(by: { hypot($0.pos.x - b.pos.x, $0.pos.y - b.pos.y) < hypot($1.pos.x - b.pos.x, $1.pos.y - b.pos.y) }) else { return nil }
        return (near.pos, true)
    }
}
