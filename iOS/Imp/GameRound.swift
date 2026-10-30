import SwiftUI

/// One round of Embers: sparks drift up the wall and flung Imps catch them. Pure rules, no views:
/// the stage's engine hands in where the Imps are and takes back what happened.
struct GameRound {
    static let length = 45.0
    /// Slower than this, an Imp is drifting rather than flying.
    static let flightSpeed = 220.0
    static let maxMultiplier = 5

    struct Mover {
        var id: UUID
        var pos: CGPoint
        var vel: CGVector
        var radius: CGFloat
    }

    enum Kind { case ember, wisp }

    struct Spark {
        var kind: Kind
        var pos: CGPoint
        var vel = CGVector.zero
        var age = 0.0
        var life = 1.0
        var radius = 5.0
        /// Where an ember rises from, it sways around this.
        var anchor = 0.0
        var phase = Double.random(in: 0...6.3)
    }

    struct Popup {
        var text: String
        var pos: CGPoint
        var age = 0.0
        var kind: Kind
    }

    enum Event {
        case caught(UUID, points: Int, multiplier: Int)
        case bonk(UUID, UUID)
        case finished
    }

    private(set) var score = 0
    private(set) var remaining = GameRound.length
    private(set) var embers: [Spark] = []
    private(set) var bursts: [Spark] = []
    private(set) var popups: [Popup] = []

    var isOver: Bool { remaining <= 0 }
    var progress: Double { 1 - max(0, remaining) / Self.length }

    private var untilEmber = 0.3
    private var untilWisp = Double.random(in: 7...12)
    private var combos: [UUID: (count: Int, calm: Double)] = [:]
    private var cooldowns: [Set<UUID>: Double] = [:]

    mutating func advance(_ dt: Double, in field: CGRect, movers: inout [Mover], calm: Bool) -> [Event] {
        guard !isOver else { return [] }
        var events: [Event] = []
        remaining -= dt
        spawn(dt, in: field, calm: calm)
        drift(dt, in: field, calm: calm)
        flights(dt, movers: movers, events: &events)
        bonks(dt, movers: &movers, calm: calm, events: &events)
        age(dt)
        if remaining <= 0 {
            remaining = 0
            events.append(.finished)
        }
        return events
    }

    // MARK: Sparks

    private mutating func spawn(_ dt: Double, in field: CGRect, calm: Bool) {
        untilEmber -= dt
        if untilEmber <= 0, embers.count < (calm ? 14 : 22) {
            untilEmber = Double.random(in: 0.3...0.6)
            let x = Double.random(in: 24...(field.width - 24))
            embers.append(Spark(kind: .ember, pos: CGPoint(x: x, y: field.maxY + 50),
                                vel: CGVector(dx: 0, dy: -Double.random(in: 80...150)),
                                radius: Double.random(in: 4...6.5), anchor: x))
        }
        untilWisp -= dt
        if untilWisp <= 0 {
            untilWisp = Double.random(in: 9...15)
            let fromLeft = Bool.random()
            let y = Double.random(in: field.minY + 40...field.midY + field.height * 0.25)
            embers.append(Spark(kind: .wisp, pos: CGPoint(x: fromLeft ? -20 : field.width + 20, y: y),
                                vel: CGVector(dx: fromLeft ? 420 : -420, dy: Double.random(in: -40...40)), radius: 7))
        }
    }

    /// Embers rise and sway, wisps dash across.
    private mutating func drift(_ dt: Double, in field: CGRect, calm: Bool) {
        for i in embers.indices {
            embers[i].age += dt
            switch embers[i].kind {
            case .ember:
                embers[i].pos.y += embers[i].vel.dy * dt
                let sway = calm ? 0 : sin(embers[i].age * 1.6 + embers[i].phase) * 16
                embers[i].pos.x = embers[i].anchor + sway
            case .wisp:
                embers[i].pos.x += embers[i].vel.dx * dt
                embers[i].pos.y += embers[i].vel.dy * dt
            }
        }
        embers.removeAll { $0.pos.y < field.minY - 40 || $0.pos.x < -60 || $0.pos.x > field.width + 60 }
    }

    // MARK: Catching

    /// An Imp in flight that touches a spark takes it, and every one in the same flight counts more.
    private mutating func flights(_ dt: Double, movers: [Mover], events: inout [Event]) {
        for m in movers {
            let speed = hypot(m.vel.dx, m.vel.dy)
            var state = combos[m.id] ?? (0, 0)
            if speed < Self.flightSpeed {
                state.calm += dt
                if state.calm > 0.5 { state.count = 0 }
                combos[m.id] = state
                continue
            }
            state.calm = 0
            for i in embers.indices.reversed() where hypot(embers[i].pos.x - m.pos.x, embers[i].pos.y - m.pos.y) < m.radius + embers[i].radius {
                let spark = embers.remove(at: i)
                state.count += 1
                let multiplier = min(state.count, Self.maxMultiplier)
                let points = (spark.kind == .wisp ? 5 : 1) * multiplier
                score += points
                popups.append(Popup(text: multiplier > 1 ? "+\(points) ×\(multiplier)" : "+\(points)", pos: spark.pos, kind: spark.kind))
                burst(at: spark.pos, kind: spark.kind, count: spark.kind == .wisp ? 10 : 5)
                events.append(.caught(m.id, points: points, multiplier: multiplier))
            }
            combos[m.id] = state
        }
        if popups.count > 8 { popups.removeFirst(popups.count - 8) }
    }

    // MARK: Bonking

    /// Two Imps meeting while one is flying: a bonk, and they bounce apart.
    private mutating func bonks(_ dt: Double, movers: inout [Mover], calm: Bool, events: inout [Event]) {
        for key in cooldowns.keys { cooldowns[key]! -= dt }
        cooldowns = cooldowns.filter { $0.value > 0 }
        guard movers.count > 1 else { return }
        for i in 0..<movers.count {
            for j in (i + 1)..<movers.count {
                var a = movers[i], b = movers[j]
                let dx = b.pos.x - a.pos.x, dy = b.pos.y - a.pos.y
                let d = max(1, hypot(dx, dy))
                let reach = a.radius + b.radius
                let pair: Set<UUID> = [a.id, b.id]
                guard d < reach, cooldowns[pair] == nil else { continue }
                guard max(hypot(a.vel.dx, a.vel.dy), hypot(b.vel.dx, b.vel.dy)) >= Self.flightSpeed else { continue }
                let nx = dx / d, ny = dy / d
                // Along the line between them they swap speeds, with a little kick so it reads.
                let closing = (a.vel.dx - b.vel.dx) * nx + (a.vel.dy - b.vel.dy) * ny
                let push = max(closing * 0.9, 380)
                a.vel.dx -= nx * (closing + push) / 2; a.vel.dy -= ny * (closing + push) / 2
                b.vel.dx += nx * (closing + push) / 2; b.vel.dy += ny * (closing + push) / 2
                let overlap = (reach - d) / 2
                a.pos.x -= nx * overlap; a.pos.y -= ny * overlap
                b.pos.x += nx * overlap; b.pos.y += ny * overlap
                movers[i] = a; movers[j] = b
                cooldowns[pair] = 1
                score += 3
                let mid = CGPoint(x: (a.pos.x + b.pos.x) / 2, y: (a.pos.y + b.pos.y) / 2)
                popups.append(Popup(text: "+3", pos: mid, kind: .ember))
                burst(at: mid, kind: .ember, count: calm ? 8 : 18, speed: 260)
                combos[a.id] = (0, 0); combos[b.id] = (0, 0)
                events.append(.bonk(a.id, b.id))
            }
        }
    }

    private mutating func burst(at p: CGPoint, kind: Kind, count: Int, speed: Double = 160) {
        for _ in 0..<count where bursts.count < 60 {
            let angle = Double.random(in: 0..<(2 * .pi)), v = Double.random(in: speed * 0.4...speed)
            bursts.append(Spark(kind: kind, pos: p, vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v),
                                life: Double.random(in: 0.35...0.7), radius: Double.random(in: 1.6...3)))
        }
    }

    private mutating func age(_ dt: Double) {
        for i in bursts.indices {
            bursts[i].age += dt
            let k = exp(-3 * dt)
            bursts[i].vel = CGVector(dx: bursts[i].vel.dx * k, dy: bursts[i].vel.dy * k)
            bursts[i].pos.x += bursts[i].vel.dx * dt
            bursts[i].pos.y += bursts[i].vel.dy * dt
        }
        bursts.removeAll { $0.age >= $0.life }
        for i in popups.indices { popups[i].age += dt }
        popups.removeAll { $0.age >= 0.9 }
    }
}
