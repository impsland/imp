import SwiftUI

/// One round of Embers: sparks drift up the wall and flung Imps catch them. Pure rules, no views:
/// the stage's engine hands in where the Imps are and takes back what happened.
///
/// A round that coaches starts with a short lesson (a line of embers to fling an Imp through, the
/// rules, a countdown) with the clock frozen, then plays like any other.
struct GameRound {
    static let length = 45.0
    /// Kindling can stretch a round, but never past this.
    static let longest = 75.0
    /// The last seconds count double.
    static let blaze = 10.0
    static let kindling = 5.0
    /// Slower than this, an Imp is drifting rather than flying.
    static let flightSpeed = 220.0
    static let maxMultiplier = 5
    static let rulesTime = 4.5
    static let countdownStep = 0.9

    static var caption: String { String(localized: "Fling an Imp through the embers") }

    struct Mover {
        var id: UUID
        var pos: CGPoint
        var vel: CGVector
        var radius: CGFloat
    }

    enum Kind { case ember, wisp, kindling, smoke }

    enum Phase { case fling, rules, countdown, playing }

    struct Spark {
        var kind: Kind
        var pos: CGPoint
        var vel = CGVector.zero
        var age = 0.0
        var life = 1.0
        var radius = 5.0
        /// Where a spark rises from, it sways around this.
        var anchor = 0.0
        var phase = Double.random(in: 0...6.3)
        /// Hangs still (the lesson's embers).
        var held = false
    }

    struct Popup {
        enum Style {
            case points, cheer, note
            var life: Double { switch self { case .points: 0.9; case .cheer: 1.5; case .note: 1.8 } }
            var size: Double { switch self { case .points: 17; case .cheer: 30; case .note: 15 } }
            var rise: Double { switch self { case .points: 36; case .cheer: 26; case .note: 10 } }
        }
        var text: String
        var pos: CGPoint
        var age = 0.0
        var kind: Kind
        var style = Style.points
    }

    /// The lesson's line: the Imp to fling, where it is, and where the line ends.
    struct Guide {
        var id: UUID
        var from: CGPoint
        var to: CGPoint
    }

    enum Event {
        case caught(UUID, points: Int, multiplier: Int)
        case kindled(UUID)
        case smoked(UUID)
        case cheered(UUID)
        case bonk(UUID, UUID)
        case blaze
        /// The lesson is over and the countdown starts.
        case countdown
        case tick(Int)
        case finished
    }

    private(set) var phase: Phase
    private(set) var score = 0
    private(set) var remaining = GameRound.length
    private(set) var elapsed = 0.0
    /// The clock ring as drawn: it eases up when kindling refills it.
    private(set) var ring = 1.0
    private(set) var kindleGlow = 0.0
    private(set) var blazeLevel = 0.0
    private(set) var inBlaze = false
    private(set) var countdown = 3
    private(set) var guide: Guide?
    private(set) var embers: [Spark] = []
    private(set) var bursts: [Spark] = []
    private(set) var popups: [Popup] = []
    /// This round's score beat the best (set by whoever keeps it).
    var isRecord = false

    var isOver: Bool { phase == .playing && remaining <= 0 }

    /// How hot the round has run: 0 at the start, 1 as the Blaze nears.
    var heat: Double {
        let t = min(1, elapsed / (Self.length - Self.blaze))
        return t * t * (3 - 2 * t)
    }

    private var field = CGRect.zero
    private var untilEmber = 0.3
    private var untilWisp = Double.random(in: 7...12)
    private var untilKindling = Double.random(in: 12...18)
    private var untilSmoke = Double.random(in: 8...10)
    private var swarms = [15 + Double.random(in: -1.5...1.5), 30 + Double.random(in: -1.5...1.5)]
    private var combos: [UUID: (count: Int, calm: Double)] = [:]
    private var cooldowns: [Set<UUID>: Double] = [:]
    private var phaseClock = 0.0
    private var firstCatch: Double?
    private var cleared = 0.0
    private var untilWave = 0.0
    private var waves = 0

    init(coaching: Bool = false) {
        phase = coaching ? .fling : .playing
    }

    mutating func advance(_ dt: Double, in field: CGRect, movers: inout [Mover], calm: Bool) -> [Event] {
        guard !isOver else { return [] }
        self.field = field
        var events: [Event] = []
        switch phase {
        case .fling:
            arrange(movers)
            drift(dt, calm: calm)
            flights(dt, movers: movers, events: &events)
            followLesson(dt)
        case .rules:
            phaseClock += dt
            if phaseClock >= Self.rulesTime { startCountdown(&events) }
        case .countdown:
            phaseClock += dt
            let n = 3 - Int(phaseClock / Self.countdownStep)
            if n < countdown {
                countdown = n
                events.append(.tick(max(n, 0)))
                if n <= 0 { begin() }
            }
        case .playing:
            play(dt, movers: &movers, calm: calm, events: &events)
        }
        age(dt)
        return events
    }

    /// After the last second: the sparks keep drifting and a new best throws a few of its own.
    mutating func settle(_ dt: Double, in field: CGRect, calm: Bool) {
        self.field = field
        drift(dt, calm: calm)
        if isRecord, waves < 5 {
            untilWave -= dt
            if untilWave <= 0 {
                untilWave = 0.18
                waves += 1
                celebrate(calm ? 8 : 16)
            }
        }
        age(dt)
    }

    /// Skips ahead: from the line, or the rules, to the countdown.
    mutating func nextStep() -> [Event] {
        var events: [Event] = []
        if phase == .fling || phase == .rules { startCountdown(&events) }
        return events
    }

    /// The Imp the lesson pointed at is gone.
    mutating func dropGuide() {
        guide = nil
        embers.removeAll { $0.held }
    }

    private mutating func play(_ dt: Double, movers: inout [Mover], calm: Bool, events: inout [Event]) {
        elapsed += dt
        remaining -= dt
        if !inBlaze, remaining <= Self.blaze { startBlaze(&events) }
        spawn(dt, calm: calm)
        drift(dt, calm: calm)
        flights(dt, movers: movers, events: &events)
        bonks(dt, movers: &movers, calm: calm, events: &events)
        if remaining <= 0 {
            remaining = 0
            events.append(.finished)
        }
    }

    private mutating func startBlaze(_ events: inout [Event]) {
        inBlaze = true
        events.append(.blaze)
        popups.append(Popup(text: String(localized: "Blaze ×2"), pos: CGPoint(x: field.midX, y: field.minY + 14), kind: .ember, style: .note))
        for spark in embers where spark.kind == .kindling { burst(at: spark.pos, kind: .kindling, count: 6) }
        embers.removeAll { $0.kind == .kindling }
    }

    // MARK: Lesson

    /// Hangs three embers in a line in the open, near the Imp closest to the middle of the screen.
    /// Until something is caught, an Imp that was flung elsewhere gets a fresh line.
    private mutating func arrange(_ movers: [Mover]) {
        guard firstCatch == nil, !movers.isEmpty else { return }
        if let guide {
            guard let imp = movers.first(where: { $0.id == guide.id }),
                  hypot(imp.vel.dx, imp.vel.dy) < 60, hypot(imp.pos.x - guide.from.x, imp.pos.y - guide.from.y) > 70 else { return }
        }
        let middle = CGPoint(x: field.midX, y: field.midY)
        let imp = guide.flatMap { g in movers.first { $0.id == g.id } }
            ?? movers.min { hypot($0.pos.x - middle.x, $0.pos.y - middle.y) < hypot($1.pos.x - middle.x, $1.pos.y - middle.y) }!
        let room = field.insetBy(dx: 56, dy: 56)
        let toMiddle = CGVector(dx: middle.x - imp.pos.x, dy: middle.y - imp.pos.y)
        let away = max(1, hypot(toMiddle.dx, toMiddle.dy))
        func spot(_ dir: CGVector, _ distance: Double) -> CGPoint {
            CGPoint(x: imp.pos.x + dir.dx * distance, y: imp.pos.y + dir.dy * distance)
        }
        var chosen = CGVector(dx: toMiddle.dx / away, dy: toMiddle.dy / away)
        var best = -Double.infinity
        for k in 0..<16 {
            let angle = Double(k) / 16 * 2 * .pi
            let dir = CGVector(dx: cos(angle), dy: sin(angle))
            let points = (0..<4).map { spot(dir, 150 + 70 * Double($0)) }
            guard points.allSatisfy({ room.contains($0) }) else { continue }
            var clearance = 200.0
            for p in points {
                for other in movers where other.id != imp.id {
                    clearance = min(clearance, hypot(p.x - other.pos.x, p.y - other.pos.y) - other.radius)
                }
            }
            let score = clearance + (dir.dx * toMiddle.dx + dir.dy * toMiddle.dy) / away * 20
            if score > best { best = score; chosen = dir }
        }
        func inside(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, room.minX), room.maxX), y: min(max(p.y, room.minY), room.maxY))
        }
        embers.removeAll { $0.held }
        for i in 0..<3 {
            let p = inside(spot(chosen, 150 + 70 * Double(i)))
            embers.append(Spark(kind: .ember, pos: p, radius: 6.5, anchor: p.x, held: true))
        }
        guide = Guide(id: imp.id, from: imp.pos, to: inside(spot(chosen, 150 + 70 * 3)))
    }

    /// Once something is caught the rest can follow, then the rules come up.
    private mutating func followLesson(_ dt: Double) {
        phaseClock += dt
        guard let first = firstCatch else { return }
        if embers.contains(where: \.held) {
            guard phaseClock - first >= 2.5 else { return }
        } else {
            cleared += dt
            guard cleared >= 0.8 else { return }
        }
        for spark in embers where spark.held { burst(at: spark.pos, kind: .ember, count: 3) }
        embers.removeAll { $0.held }
        guide = nil
        phase = .rules
        phaseClock = 0
    }

    private mutating func startCountdown(_ events: inout [Event]) {
        embers.removeAll { $0.held }
        guide = nil
        phase = .countdown
        phaseClock = 0
        countdown = 3
        events.append(.countdown)
        events.append(.tick(3))
    }

    /// The clock starts from nothing: what the lesson scored doesn't count.
    private mutating func begin() {
        phase = .playing
        score = 0
        combos = [:]
        popups = []
        embers = []
        untilEmber = 0.3
    }

    // MARK: Sparks

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private mutating func spawn(_ dt: Double, calm: Bool) {
        let heat = heat
        let pace = Self.lerp(0.85, 1.45, heat) * (inBlaze ? 1.1 : 1)
        let width = field.width
        untilEmber -= dt
        let cap = Int(Self.lerp(calm ? 10 : 14, calm ? 16 : 26, heat))
        if untilEmber <= 0, embers.filter({ $0.kind == .ember }).count < cap {
            untilEmber = Double.random(in: 0.3...0.6) * Self.lerp(1.6, 0.6, heat) * (inBlaze ? 0.85 : 1)
            let x = Double.random(in: 24...(width - 24))
            embers.append(Spark(kind: .ember, pos: CGPoint(x: x, y: field.maxY + 50),
                                vel: CGVector(dx: 0, dy: -Double.random(in: 80...150) * pace),
                                radius: Double.random(in: 4...6.5), anchor: x))
        }
        untilWisp -= dt
        if untilWisp <= 0 {
            untilWisp = Double.random(in: 9...15)
            let fromLeft = Bool.random()
            let y = Double.random(in: field.minY + 40...field.midY + field.height * 0.25)
            embers.append(Spark(kind: .wisp, pos: CGPoint(x: fromLeft ? -20 : width + 20, y: y),
                                vel: CGVector(dx: fromLeft ? 420 : -420, dy: Double.random(in: -40...40)), radius: 7))
        }
        untilKindling -= dt
        if untilKindling <= 0 {
            untilKindling = Double.random(in: 12...18)
            if remaining > Self.blaze + 6, !embers.contains(where: { $0.kind == .kindling }) {
                let x = Double.random(in: 60...(width - 60))
                embers.append(Spark(kind: .kindling, pos: CGPoint(x: x, y: field.maxY + 50),
                                    vel: CGVector(dx: 0, dy: -Double.random(in: 70...85)), radius: 8.5, anchor: x))
            }
        }
        untilSmoke -= dt
        if untilSmoke <= 0 {
            untilSmoke = Self.lerp(4.2, 2.2, heat) * Double.random(in: 0.8...1.2)
            let puffs = calm ? 2 : 2 + Int(heat * 3.2)
            if embers.filter({ $0.kind == .smoke }).count < puffs {
                let r = Double.random(in: 30...42)
                let x = Double.random(in: 40...(width - 40))
                embers.append(Spark(kind: .smoke, pos: CGPoint(x: x, y: field.maxY + r + 20),
                                    vel: CGVector(dx: 0, dy: -Double.random(in: 38...58)), radius: r, anchor: x))
            }
        }
        if let when = swarms.first, elapsed >= when {
            swarms.removeFirst()
            if !inBlaze { swarm(pace: pace, in: field) }
        }
    }

    /// A column of embers that rises together, tight enough to take several in one fling.
    private mutating func swarm(pace: Double, in field: CGRect) {
        let x = Double.random(in: 70...(field.width - 70))
        let speed = Double.random(in: 100...130) * pace
        let phase = Double.random(in: 0...6.3)
        for i in 0..<Int.random(in: 7...9) {
            let anchor = x + Double.random(in: -5...5)
            embers.append(Spark(kind: .ember, pos: CGPoint(x: anchor, y: field.maxY + 50 + 34 * Double(i)),
                                vel: CGVector(dx: 0, dy: -speed), radius: 5.5, anchor: anchor, phase: phase))
        }
    }

    /// Embers and kindling rise and sway, smoke billows up slowly, wisps dash across.
    private mutating func drift(_ dt: Double, calm: Bool) {
        for i in embers.indices {
            embers[i].age += dt
            guard !embers[i].held else { continue }
            switch embers[i].kind {
            case .wisp:
                embers[i].pos.x += embers[i].vel.dx * dt
                embers[i].pos.y += embers[i].vel.dy * dt
            case .ember, .kindling, .smoke:
                embers[i].pos.y += embers[i].vel.dy * dt
                let (reach, rate) = Self.sway(embers[i].kind)
                let sway = calm ? 0 : sin(embers[i].age * rate + embers[i].phase) * reach
                embers[i].pos.x = embers[i].anchor + sway
            }
        }
        let top = field.minY - 40
        embers.removeAll { ($0.kind == .smoke ? $0.pos.y + $0.radius : $0.pos.y) < top || $0.pos.x < -60 || $0.pos.x > field.width + 60 }
    }

    private static func sway(_ kind: Kind) -> (reach: Double, rate: Double) {
        switch kind {
        case .kindling: (20, 1.1)
        case .smoke: (28, 0.55)
        default: (16, 1.6)
        }
    }

    // MARK: Catching

    /// An Imp in flight that touches a spark takes it, and every one in the same flight counts more.
    /// Kindling adds time, smoke costs points.
    private mutating func flights(_ dt: Double, movers: [Mover], events: inout [Event]) {
        let doubled = inBlaze ? 2 : 1
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
            for i in embers.indices.reversed() {
                let spark = embers[i]
                let reach = spark.kind == .smoke ? spark.radius * 0.6 : spark.radius
                guard hypot(spark.pos.x - m.pos.x, spark.pos.y - m.pos.y) < m.radius + reach else { continue }
                embers.remove(at: i)
                switch spark.kind {
                case .ember, .wisp:
                    if spark.held, firstCatch == nil { firstCatch = phaseClock }
                    state.count += 1
                    let multiplier = min(state.count, Self.maxMultiplier)
                    let points = (spark.kind == .wisp ? 5 : 1) * multiplier * doubled
                    score += points
                    popups.append(Popup(text: multiplier > 1 ? "+\(points) ×\(multiplier)" : "+\(points)", pos: onScreen(spark.pos), kind: spark.kind))
                    burst(at: spark.pos, kind: spark.kind, count: spark.kind == .wisp ? 10 : 5)
                    events.append(.caught(m.id, points: points, multiplier: multiplier))
                    if state.count == Self.maxMultiplier {
                        popups.append(Popup(text: String(localized: "Ablaze!"), pos: onScreen(CGPoint(x: spark.pos.x, y: spark.pos.y - 34)),
                                            kind: .ember, style: .cheer))
                        events.append(.cheered(m.id))
                    }
                case .kindling:
                    let room = max(0, Self.longest - (elapsed + remaining))
                    remaining += min(Self.kindling, room)
                    kindleGlow = 1
                    popups.append(Popup(text: String(localized: "+5s"), pos: onScreen(spark.pos), kind: .kindling))
                    burst(at: spark.pos, kind: .kindling, count: 9)
                    events.append(.kindled(m.id))
                case .smoke:
                    let lost = min(2, score)
                    score -= lost
                    state.count = 0
                    if lost > 0 { popups.append(Popup(text: "−\(lost)", pos: onScreen(spark.pos), kind: .smoke)) }
                    burst(at: spark.pos, kind: .smoke, count: 10, speed: 130, size: 2.5...4.5, life: 0.5...0.9)
                    events.append(.smoked(m.id))
                }
            }
            combos[m.id] = state
        }
        if popups.count > 8 { popups.removeFirst(popups.count - 8) }
    }

    private func onScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 50), max(50, field.width - 50)), y: p.y)
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
                let points = inBlaze ? 6 : 3
                score += points
                let mid = CGPoint(x: (a.pos.x + b.pos.x) / 2, y: (a.pos.y + b.pos.y) / 2)
                popups.append(Popup(text: "+\(points)", pos: onScreen(mid), kind: .ember))
                burst(at: mid, kind: .ember, count: calm ? 8 : 18, speed: 260)
                combos[a.id] = (0, 0); combos[b.id] = (0, 0)
                events.append(.bonk(a.id, b.id))
            }
        }
    }

    private mutating func burst(at p: CGPoint, kind: Kind, count: Int, speed: Double = 160,
                                size: ClosedRange<Double> = 1.6...3, life: ClosedRange<Double> = 0.35...0.7) {
        for _ in 0..<count where bursts.count < 60 {
            let angle = Double.random(in: 0..<(2 * .pi)), v = Double.random(in: speed * 0.4...speed)
            bursts.append(Spark(kind: kind, pos: p, vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v),
                                life: Double.random(in: life), radius: Double.random(in: size)))
        }
    }

    /// A fan of sparks over the end card.
    private mutating func celebrate(_ count: Int) {
        for _ in 0..<count where bursts.count < 100 {
            let angle = Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05), v = Double.random(in: 200...440)
            bursts.append(Spark(kind: Bool.random() ? .ember : .wisp,
                                pos: CGPoint(x: field.midX + Double.random(in: -140...140), y: field.midY - 130),
                                vel: CGVector(dx: cos(angle) * v, dy: sin(angle) * v),
                                life: Double.random(in: 0.6...1.1), radius: Double.random(in: 1.8...3.6)))
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
        popups.removeAll { $0.age >= $0.style.life }

        let target = phase == .playing ? min(1, max(0, remaining) / Self.length) : 1
        ring = target < ring ? target : ring + (target - ring) * min(1, dt * 5)
        kindleGlow = max(0, kindleGlow - dt * 1.6)
        let heated = inBlaze && !isOver ? 1.0 : 0
        blazeLevel += (heated - blazeLevel) * min(1, dt * 2.5)
    }
}
