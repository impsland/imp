import SwiftUI

/// One round of Embers: sparks drift up the wall and flung Imps catch them. Pure rules, no views:
/// the stage's engine hands in where the Imps are and takes back what happened.
///
/// A round that coaches starts with a short lesson (a line of embers to fling an Imp through, the
/// rules, a countdown) with the clock frozen, then plays like any other.
///
/// The embers rise in waves (a column, a slant, a chevron, two columns), each judged as a whole:
/// catch every ember of a wave for a bonus. A round with nothing got away, and a round with no smoke
/// hit, each earn a finale. Twice in a round a special phase changes the rules for a few seconds
/// (rings to take in one flight, a storm of wisps, a shower of gold), announced by a banner; then
/// comes the Blaze.
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
    static let rulesTime = 6.0
    static let countdownStep = 0.9
    /// What a round with no smoke hit earns at the end.
    static let cleanBonus = 15
    /// What a round with nothing got away earns at the end.
    static let flawlessBonus = 25
    /// A round needs this many embers judged before "nothing got away" means something.
    static let flawlessMinimum = 20
    static let ringBonus = 8

    static var caption: String { String(localized: "Fling an Imp through the embers") }

    struct Mover {
        var id: UUID
        var pos: CGPoint
        var vel: CGVector
        var radius: CGFloat
    }

    enum Kind { case ember, wisp, kindling, smoke, gold }

    enum Phase { case fling, rules, countdown, playing }

    /// A stretch of the round with its own rules.
    struct Special {
        enum Kind: CaseIterable { case chain, storm, shower }
        var kind: Kind
        var elapsed = 0.0
        /// The banner has the stage first, then the sparks come.
        static let intro = 1.3
        var duration: Double { kind == .chain ? 9.5 : 7 }
        var remaining: Double { max(0, duration - elapsed) }
        /// 0…1 across the phase.
        var progress: Double { min(1, elapsed / duration) }
        var inIntro: Bool { elapsed < Self.intro }
    }

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
        /// The wave it rises with, judged as a whole.
        var group: Int?
        /// Part of a ring: drawn joined to its neighbours.
        var ring = false
    }

    /// One wave of embers, from the moment it rises to the last one caught or gone.
    private struct Wave {
        var total: Int
        var caught = 0
        var lost = 0
        var ring = false
        /// Which flights took its embers: a ring pays when a single one took them all.
        var flights: Set<Flight> = []
    }

    private struct Flight: Hashable {
        var id: UUID
        var number: Int
    }

    /// How an Imp's flights are going: the combo, the quiet since it slowed, which flight it is.
    private struct Run {
        var count = 0
        var calm = 0.0
        var flight = 0
        var flying = false
    }

    struct Popup {
        enum Style {
            case points, cheer, note
            /// A prize at the end of the round, over the end card's top.
            case award
            var life: Double { switch self { case .points: 0.9; case .cheer: 1.5; case .note: 1.8; case .award: 3 } }
            var size: Double { switch self { case .points: 17; case .cheer: 30; case .note: 15; case .award: 24 } }
            var rise: Double { switch self { case .points: 36; case .cheer: 26; case .note: 10; case .award: 8 } }
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
        /// Every ember of a wave caught (`streak` waves in a row), by the Imp that took the last.
        case perfectWave(UUID?, streak: Int, points: Int)
        /// A ring caught in one flight.
        case ring(UUID?, points: Int)
        case special(Special.Kind)
        case specialEnded(Special.Kind)
        /// The round ended with no smoke hit.
        case cleanBurn(points: Int)
        /// The round ended with no ember got away.
        case flawless(points: Int)
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
    private(set) var special: Special?
    private(set) var countdown = 3
    private(set) var guide: Guide?
    private(set) var embers: [Spark] = []
    private(set) var bursts: [Spark] = []
    private(set) var popups: [Popup] = []
    /// This round's score beat the best (set by whoever keeps it).
    var isRecord = false

    // What the round did, for the end card and the little badges while it runs.
    private(set) var smokeHits = 0
    /// Embers that rose out of the top uncaught.
    private(set) var escaped = 0
    /// Embers of waves that were caught or got away.
    private(set) var judged = 0
    private(set) var wavesJudged = 0
    private(set) var perfectWaves = 0
    private(set) var perfectStreak = 0
    private(set) var rings = 0
    /// The most sparks taken in one flight.
    private(set) var bestCombo = 0
    private(set) var cleanBurn = false
    private(set) var flawless = false
    /// Clean rounds in a row, this one included (set by whoever keeps it).
    var cleanStreak = 0
    /// Rounds with nothing got away, this one included (set by whoever keeps it).
    var flawlessRounds = 0

    var isOver: Bool { phase == .playing && remaining <= 0 }

    /// No smoke hit so far.
    var isClean: Bool { smokeHits == 0 }
    /// Nothing got away so far.
    var isUntouched: Bool { escaped == 0 }

    /// How hot the round has run: 0 at the start, 1 as the Blaze nears.
    var heat: Double {
        let t = min(1, elapsed / (Self.length - Self.blaze))
        return t * t * (3 - 2 * t)
    }

    private var field = CGRect.zero
    private var untilWisp = Double.random(in: 7...12)
    private var untilKindling = Double.random(in: 12...18)
    private var untilSmoke = Double.random(in: 8...10)
    private var untilWave = 0.5
    private var plan: [(at: Double, kind: Special.Kind)]
    private var nextGroup = 0
    private var wavebook: [Int: Wave] = [:]
    private var lostGroups: [Int] = []
    /// Until the special phase brings its next ring, wisp or gold.
    private var untilBring = 0.0
    private var ringsBrought = 0
    private var lastLane = 0.0
    private var combos: [UUID: Run] = [:]
    private var cooldowns: [Set<UUID>: Double] = [:]
    private var phaseClock = 0.0
    private var firstCatch: Double?
    private var cleared = 0.0
    private var shows = 0
    private var untilShow = 0.0

    init(coaching: Bool = false) {
        phase = coaching ? .fling : .playing
        let kinds = Special.Kind.allCases.shuffled()
        plan = [(12 + Double.random(in: -1.5...1.5), kinds[0]), (25 + Double.random(in: -1.5...1.5), kinds[1])]
    }

    mutating func advance(_ dt: Double, in field: CGRect, movers: inout [Mover], calm: Bool) -> [Event] {
        guard !isOver else { return [] }
        self.field = field
        var events: [Event] = []
        switch phase {
        case .fling:
            arrange(movers)
            drift(dt, calm: calm)
            lostGroups.removeAll()
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

    /// How many bursts of sparks the end of the round throws for its prizes.
    private var showTotal: Int { flawless ? 9 : max(cleanBurn ? 4 : 0, isRecord ? 5 : 0) }

    /// The round is over and its last sparks have gone: only the card is left to draw.
    var isSettled: Bool { isOver && embers.isEmpty && bursts.isEmpty && popups.isEmpty && shows >= showTotal }

    /// After the last second: the sparks keep drifting and a prize throws a few of its own.
    mutating func settle(_ dt: Double, in field: CGRect, calm: Bool) {
        self.field = field
        drift(dt, calm: calm)
        lostGroups.removeAll()
        if shows < showTotal {
            untilShow -= dt
            if untilShow <= 0 {
                untilShow = flawless ? 0.14 : 0.18
                shows += 1
                celebrate(calm ? 8 : 16, kind: flawless ? .gold : (cleanBurn && !isRecord ? .wisp : nil))
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
        runSpecials(dt, calm: calm, events: &events)
        spawn(dt, calm: calm)
        drift(dt, calm: calm)
        judgeLost(&events)
        flights(dt, movers: movers, events: &events)
        bonks(dt, movers: &movers, calm: calm, events: &events)
        if remaining <= 0 {
            remaining = 0
            finale(&events)
            events.append(.finished)
        }
    }

    private mutating func startBlaze(_ events: inout [Event]) {
        inBlaze = true
        if let special { events.append(.specialEnded(special.kind)) }
        special = nil
        events.append(.blaze)
        popups.append(Popup(text: String(localized: "Blaze ×2"), pos: CGPoint(x: field.midX, y: field.minY + 14), kind: .ember, style: .note))
        for spark in embers where spark.kind == .kindling { burst(at: spark.pos, kind: .kindling, count: 6) }
        embers.removeAll { $0.kind == .kindling }
    }

    /// The prizes of a round that ended clean, and of one where nothing got away.
    private mutating func finale(_ events: inout [Event]) {
        var y = field.minY + 8
        if escaped == 0, judged >= Self.flawlessMinimum {
            flawless = true
            score += Self.flawlessBonus
            popups.append(Popup(text: String(localized: "Nothing got away! +\(Self.flawlessBonus)"),
                                pos: CGPoint(x: field.midX, y: y), kind: .gold, style: .award))
            events.append(.flawless(points: Self.flawlessBonus))
            y += 34
        }
        if smokeHits == 0 {
            cleanBurn = true
            score += Self.cleanBonus
            popups.append(Popup(text: String(localized: "Clean burn! +\(Self.cleanBonus)"),
                                pos: CGPoint(x: field.midX, y: y), kind: .wisp, style: .award))
            events.append(.cleanBurn(points: Self.cleanBonus))
        }
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
        untilWave = 0.5
        bestCombo = 0
    }

    // MARK: Sparks

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    private mutating func spawn(_ dt: Double, calm: Bool) {
        let heat = heat
        let pace = Self.lerp(0.85, 1.45, heat) * (inBlaze ? 1.1 : 1)
        let width = field.width
        // Waves of embers, except while a special phase brings its own sparks.
        untilWave -= dt
        if untilWave <= 0, special == nil, remaining > 4.5 {
            untilWave = Self.lerp(4.2, 3, heat) * (inBlaze ? 0.85 : 1) * (calm ? 1.15 : 1) * Double.random(in: 0.92...1.08)
            wave(pace: pace, heat: heat)
        }
        let quiet = special != nil
        untilWisp -= dt
        if untilWisp <= 0 {
            untilWisp = Double.random(in: 9...15)
            if !quiet {
                let fromLeft = Bool.random()
                let y = Double.random(in: field.minY + 40...field.midY + field.height * 0.25)
                embers.append(Spark(kind: .wisp, pos: CGPoint(x: fromLeft ? -20 : width + 20, y: y),
                                    vel: CGVector(dx: fromLeft ? 420 : -420, dy: Double.random(in: -40...40)), radius: 7))
            }
        }
        untilKindling -= dt
        if untilKindling <= 0 {
            untilKindling = Double.random(in: 12...18)
            if remaining > Self.blaze + 6, !quiet, !embers.contains(where: { $0.kind == .kindling }) {
                let x = Double.random(in: 60...(width - 60))
                embers.append(Spark(kind: .kindling, pos: CGPoint(x: x, y: field.maxY + 50),
                                    vel: CGVector(dx: 0, dy: -Double.random(in: 70...85)), radius: 8.5, anchor: x))
            }
        }
        untilSmoke -= dt
        if untilSmoke <= 0 {
            untilSmoke = Self.lerp(4.2, 2.2, heat) * Double.random(in: 0.8...1.2)
            let puffs = calm ? 2 : 2 + Int(heat * 3.2)
            // No smoke while a special phase is on: the rules are the point.
            if !quiet, embers.filter({ $0.kind == .smoke }).count < puffs {
                let r = Double.random(in: 30...42)
                let x = Double.random(in: 40...(width - 40))
                embers.append(Spark(kind: .smoke, pos: CGPoint(x: x, y: field.maxY + r + 20),
                                    vel: CGVector(dx: 0, dy: -Double.random(in: 38...58)), radius: r, anchor: x))
            }
        }
    }

    /// A group of embers that rises together in one shape, tight enough to take whole in a fling.
    /// All of them sway as one, so the shape holds.
    private mutating func wave(pace: Double, heat: Double) {
        let count = 4 + Int(heat * 2.6) + Int.random(in: 0...1)
        let speed = Double.random(in: 95...125) * pace
        let phase = Double.random(in: 0...6.3)
        let x = Double.random(in: 120...(field.width - 120))
        let tilt = Bool.random() ? 1.0 : -1.0
        var offsets: [(dx: Double, dy: Double)] = []
        switch Int.random(in: 0..<4) {
        case 0: // a column
            offsets = (0..<count).map { (0, 34 * Double($0)) }
        case 1: // a slant
            offsets = (0..<count).map { (i: Int) -> (dx: Double, dy: Double) in (tilt * 22 * (Double(i) - Double(count - 1) / 2), 32 * Double(i)) }
        case 2: // a chevron
            let mid = Double(count - 1) / 2
            offsets = (0..<count).map { (i: Int) -> (dx: Double, dy: Double) in (28 * (Double(i) - mid), 26 * abs(Double(i) - mid)) }
        default: // two columns side by side
            offsets = (0..<count).map { (i: Int) -> (dx: Double, dy: Double) in
                let left = i % 2 == 0
                return (left ? -26 : 26, 34 * Double(i / 2) + (left ? 0 : 14))
            }
        }
        launch(offsets, around: x, speed: speed, phase: phase, ring: false)
    }

    /// Puts a shape of counted embers on the way up, judged together.
    private mutating func launch(_ offsets: [(dx: Double, dy: Double)], around x: Double, speed: Double, phase: Double,
                                 ring: Bool, baseY: Double? = nil) {
        let id = nextGroup
        nextGroup += 1
        let base = baseY ?? field.maxY + 50
        let edge = field.width - 30
        for o in offsets {
            let anchor = min(max(x + o.dx, 30 - 16), edge + 16)
            embers.append(Spark(kind: .ember, pos: CGPoint(x: anchor, y: base + o.dy), vel: CGVector(dx: 0, dy: -speed),
                                radius: ring ? 6 : 5.5, anchor: anchor, phase: phase, group: id, ring: ring))
        }
        wavebook[id] = Wave(total: offsets.count, ring: ring)
    }

    // MARK: Special phases

    /// Starts the next special phase on time, runs the one under way, ends it when it's done.
    private mutating func runSpecials(_ dt: Double, calm: Bool, events: inout [Event]) {
        if special == nil, !inBlaze, let next = plan.first, elapsed >= next.at {
            plan.removeFirst()
            special = Special(kind: next.kind)
            untilBring = Special.intro
            ringsBrought = 0
            events.append(.special(next.kind))
            return
        }
        guard var s = special else { return }
        s.elapsed += dt
        special = s
        if s.elapsed >= s.duration {
            special = nil
            untilWave = 1.4
            events.append(.specialEnded(s.kind))
            return
        }
        guard !s.inIntro else { return }
        untilBring -= dt
        guard untilBring <= 0 else { return }
        switch s.kind {
        case .chain:
            untilBring = 2.7
            // A ring of eight, small enough for one Imp to take whole, rising slowly.
            let x = ringsBrought % 2 == 0 ? Double.random(in: 110...(field.width / 2)) : Double.random(in: (field.width / 2)...(field.width - 110))
            ringsBrought += 1
            let offsets = (0..<8).map { k -> (dx: Double, dy: Double) in
                let a = Double(k) / 8 * 2 * .pi
                return (46 * cos(a), 46 * sin(a))
            }
            launch(offsets, around: x, speed: 88, phase: Double.random(in: 0...6.3), ring: true, baseY: field.maxY + 100)
        case .storm:
            untilBring = Double.random(in: 0.42...0.62) * (calm ? 1.3 : 1)
            // Wisps cross in lanes that don't repeat, slower than the lone wisp so they can be caught.
            var y = Double.random(in: field.minY + 60...field.maxY - 140)
            if abs(y - lastLane) < 90 { y = y > field.midY ? y - 110 : y + 110 }
            lastLane = y
            let fromLeft = Bool.random()
            embers.append(Spark(kind: .wisp, pos: CGPoint(x: fromLeft ? -20 : field.width + 20, y: y),
                                vel: CGVector(dx: fromLeft ? 300 : -300, dy: Double.random(in: -25...25)), radius: 7))
        case .shower:
            untilBring = Double.random(in: 0.2...0.32) * (calm ? 1.3 : 1)
            let x = Double.random(in: 40...(field.width - 40))
            embers.append(Spark(kind: .gold, pos: CGPoint(x: x, y: field.minY - 24),
                                vel: CGVector(dx: 0, dy: Double.random(in: 150...210)), radius: 6.5, anchor: x))
        }
    }

    /// Embers and kindling rise and sway, gold falls, smoke billows up slowly, wisps dash across.
    private mutating func drift(_ dt: Double, calm: Bool) {
        for i in embers.indices {
            embers[i].age += dt
            guard !embers[i].held else { continue }
            switch embers[i].kind {
            case .wisp:
                embers[i].pos.x += embers[i].vel.dx * dt
                embers[i].pos.y += embers[i].vel.dy * dt
            case .ember, .kindling, .smoke, .gold:
                embers[i].pos.y += embers[i].vel.dy * dt
                let (reach, rate) = Self.sway(embers[i].kind)
                let sway = calm ? 0 : sin(embers[i].age * rate + embers[i].phase) * reach
                embers[i].pos.x = embers[i].anchor + sway
            }
        }
        let top = field.minY - 40
        let bottom = field.maxY + 70
        embers.removeAll { spark in
            let gone: Bool
            switch spark.kind {
            case .smoke: gone = spark.pos.y + spark.radius < top
            case .gold: gone = spark.pos.y > bottom
            default: gone = spark.pos.y < top
            }
            guard gone || spark.pos.x < -60 || spark.pos.x > field.width + 60 else { return false }
            // An ember that left the top uncaught got away.
            if spark.kind == .ember, !spark.held, let group = spark.group { lostGroups.append(group) }
            return true
        }
    }

    private static func sway(_ kind: Kind) -> (reach: Double, rate: Double) {
        switch kind {
        case .kindling: (20, 1.1)
        case .smoke: (28, 0.55)
        case .gold: (18, 2.2)
        default: (16, 1.6)
        }
    }

    // MARK: Judging waves

    /// Embers that left the top: each is a miss, and may close a wave.
    private mutating func judgeLost(_ events: inout [Event]) {
        let groups = lostGroups
        lostGroups.removeAll()
        for group in groups {
            escaped += 1
            judged += 1
            perfectStreak = 0
            wavebook[group]?.lost += 1
            settleWave(group, by: nil, at: nil, events: &events)
        }
    }

    /// A wave is judged when each of its embers is either caught or gone. Caught whole, it pays a
    /// bonus (more for each wave in a row), and a ring taken in a single flight pays one of its own.
    private mutating func settleWave(_ group: Int, by imp: UUID?, at spot: CGPoint?, events: inout [Event]) {
        guard let wave = wavebook[group], wave.caught + wave.lost >= wave.total else { return }
        wavebook[group] = nil
        wavesJudged += 1
        guard wave.lost == 0 else { return }
        perfectWaves += 1
        perfectStreak += 1
        let doubled = inBlaze ? 2 : 1
        let waveBonus = 5 * min(perfectStreak, 3) * doubled
        let ringPays = wave.ring && wave.flights.count == 1
        let ringBonus = ringPays ? Self.ringBonus * doubled : 0
        score += waveBonus + ringBonus
        let at = onScreen(spot ?? CGPoint(x: field.midX, y: field.midY))
        // One event per judgement, so a ring buzzes and animates once (not as a ring and a wave).
        if ringPays {
            rings += 1
            popups.append(Popup(text: String(localized: "Ring! +\(waveBonus + ringBonus)"), pos: at, kind: .ember, style: .cheer))
            events.append(.ring(imp, points: waveBonus + ringBonus))
        } else {
            let text = perfectStreak > 1 ? String(localized: "Perfect ×\(perfectStreak)! +\(waveBonus)")
                                         : String(localized: "Perfect wave! +\(waveBonus)")
            popups.append(Popup(text: text, pos: at, kind: .ember, style: .cheer))
            events.append(.perfectWave(imp, streak: perfectStreak, points: waveBonus))
        }
    }

    // MARK: Catching

    /// An Imp in flight that touches a spark takes it, and every one in the same flight counts more.
    /// Kindling adds time, smoke costs points.
    private mutating func flights(_ dt: Double, movers: [Mover], events: inout [Event]) {
        let doubled = inBlaze ? 2 : 1
        for m in movers {
            let speed = hypot(m.vel.dx, m.vel.dy)
            var state = combos[m.id] ?? Run()
            if speed < Self.flightSpeed {
                state.calm += dt
                if state.calm > 0.5 {
                    // The flight is over; the next fling is a new one.
                    if state.flying { state.flight += 1 }
                    state.flying = false
                    state.count = 0
                }
                combos[m.id] = state
                continue
            }
            state.calm = 0
            state.flying = true
            for i in embers.indices.reversed() {
                let spark = embers[i]
                let reach = spark.kind == .smoke ? spark.radius * 0.6 : spark.radius
                guard hypot(spark.pos.x - m.pos.x, spark.pos.y - m.pos.y) < m.radius + reach else { continue }
                embers.remove(at: i)
                switch spark.kind {
                case .ember, .wisp, .gold:
                    if spark.held, firstCatch == nil { firstCatch = phaseClock }
                    state.count += 1
                    bestCombo = max(bestCombo, state.count)
                    let multiplier = min(state.count, Self.maxMultiplier)
                    let base = spark.kind == .wisp ? 5 : spark.kind == .gold ? 3 : 1
                    let points = base * multiplier * doubled
                    score += points
                    popups.append(Popup(text: multiplier > 1 ? "+\(points) ×\(multiplier)" : "+\(points)", pos: onScreen(spark.pos), kind: spark.kind))
                    burst(at: spark.pos, kind: spark.kind, count: spark.kind == .ember ? 5 : 10)
                    events.append(.caught(m.id, points: points, multiplier: multiplier))
                    if state.count == Self.maxMultiplier {
                        popups.append(Popup(text: String(localized: "Ablaze!"), pos: onScreen(CGPoint(x: spark.pos.x, y: spark.pos.y - 34)),
                                            kind: .ember, style: .cheer))
                        events.append(.cheered(m.id))
                    }
                    if let group = spark.group {
                        judged += 1
                        wavebook[group]?.caught += 1
                        wavebook[group]?.flights.insert(Flight(id: m.id, number: state.flight))
                        settleWave(group, by: m.id, at: spark.pos, events: &events)
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
                    state.flight += 1
                    smokeHits += 1
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
                for id in [a.id, b.id] {
                    var run = combos[id] ?? Run()
                    run.count = 0
                    run.calm = 0
                    run.flight += 1
                    combos[id] = run
                }
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

    /// A fan of sparks over the end card: gold for a round where nothing got away, cool blue for a
    /// clean one, ember and wisp for a new best.
    private mutating func celebrate(_ count: Int, kind: Kind?) {
        for _ in 0..<count where bursts.count < 100 {
            let angle = Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05), v = Double.random(in: 200...440)
            bursts.append(Spark(kind: kind ?? (Bool.random() ? .ember : .wisp),
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
