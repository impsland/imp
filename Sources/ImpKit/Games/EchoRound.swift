import Foundation

/// A small generator that gives the same numbers for the same seed, so a round can be replayed in a test.
public struct EchoRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One round of Echo, the memory game: the Imps light runes in a growing sequence and the player
/// repeats it by tapping. Pure rules, no views: the stage hands in time and taps, and takes back
/// what happened.
///
/// A round that coaches starts with a guided step (a short sequence to repeat, with nothing at
/// stake), the rules, and a countdown. Then the sequence starts at one rune and grows by one each
/// time it is repeated right. A wrong tap costs a life and the same sequence plays again; with
/// three lives gone the round is over. Clean levels (no wrong tap) pay double, and every fifth
/// one wins a life back.
public struct EchoRound: Sendable {
    public static let runes = 4
    public static let lives = 3
    /// Repeating a sequence this long wins the round outright.
    public static let longest = 16
    /// How long the guided step's sequence is.
    public static let lessonLength = 2
    public static let rulesTime = 4.5
    public static let countdownStep = 0.9
    /// Idle this long on the player's turn and the next rune gives a hint.
    public static let hintAfter = 5.0

    public enum Phase: Equatable, Sendable {
        case rules, countdown
        /// The Imps are lighting the sequence.
        case watching
        /// The player's turn.
        case repeating
        /// A breath between sequences (cheering, or dizzy).
        case between
        case over
    }

    public enum Event: Equatable, Sendable {
        /// An Imp sets off for a rune (it lights when the Imp lands: `light`).
        case hop(rune: Int, index: Int)
        case light(rune: Int, index: Int)
        case yourTurn(length: Int)
        /// A right tap: the `index`th rune of the sequence.
        case tapped(rune: Int, index: Int)
        /// The whole sequence repeated. `clean`: with no wrong tap. `gainedLife`: a life won back.
        case cleared(length: Int, points: Int, clean: Bool, streak: Int, gainedLife: Bool)
        case mistake(rune: Int, expected: Int, livesLeft: Int)
        /// The player is stuck: this rune is next.
        case hint(rune: Int)
        /// The guided step is done: the rules come up.
        case rules
        case countdown
        case tick(Int)
        case finished
    }

    public private(set) var phase: Phase
    /// The guided step is on (a short sequence, nothing at stake).
    public private(set) var isLesson: Bool
    public private(set) var score = 0
    public private(set) var lives = EchoRound.lives
    public private(set) var sequence: [Int] = []
    /// How far the player has got through the sequence.
    public private(set) var position = 0
    /// The longest sequence repeated right so far.
    public private(set) var level = 0
    /// Levels in a row with no wrong tap.
    public private(set) var streak = 0
    public private(set) var mistakes = 0
    public private(set) var countdown = 3
    /// The rune the player is nudged towards.
    public private(set) var hinted: Int?
    /// How much each rune glows, 0…1.
    public private(set) var glow = [Double](repeating: 0, count: EchoRound.runes)
    /// Won by repeating the longest sequence.
    public private(set) var completed = false
    /// This round's score beat the best (set by whoever keeps it).
    public var isRecord = false

    private var rng: EchoRandom
    private var clock = 0.0
    private var idle = 0.0
    private var hops = 0
    private var lights = 0
    private var levelClean = true
    private var breath = 0.0

    public init(coaching: Bool = false, seed: UInt64 = .random(in: .min ... .max)) {
        rng = EchoRandom(seed: seed)
        isLesson = coaching
        phase = .watching
        sequence = Self.draw(count: coaching ? Self.lessonLength : 1, from: &rng)
        clock = coaching ? -0.5 : -0.9
    }

    /// Seconds between two runes lighting: quicker as the sequence grows.
    public static func interval(for length: Int) -> Double {
        let t = min(1, Double(max(1, length) - 1) / 10)
        return 0.65 + (0.36 - 0.65) * t
    }

    /// How long a hop takes before its rune lights.
    public static func lead(for length: Int) -> Double { min(0.26, interval(for: length) * 0.7) }

    /// How long a rune stays lit.
    public var glowTime: Double { max(0.3, Self.interval(for: max(1, sequence.count)) * 0.95) }

    public var length: Int { sequence.count }

    /// The rune the player should tap next.
    public var expected: Int? { phase == .repeating && position < sequence.count ? sequence[position] : nil }

    public var isOver: Bool { phase == .over }

    // MARK: Time

    public mutating func advance(_ dt: Double) -> [Event] {
        var events: [Event] = []
        for i in glow.indices { glow[i] = max(0, glow[i] - dt / glowTime) }
        switch phase {
        case .rules:
            clock += dt
            if clock >= Self.rulesTime { startCountdown(&events) }
        case .countdown:
            clock += dt
            let n = 3 - Int(clock / Self.countdownStep)
            if n < countdown {
                countdown = n
                events.append(.tick(max(n, 0)))
                if n <= 0 { begin() }
            }
        case .watching:
            clock += dt
            show(&events)
        case .repeating:
            idle += dt
            if idle >= Self.hintAfter, hinted == nil, let next = expected {
                hinted = next
                events.append(.hint(rune: next))
            }
        case .between:
            breath -= dt
            if breath <= 0 { startWatching() }
        case .over:
            break
        }
        return events
    }

    /// Plays the sequence: each rune hops, then lights; after the last the player's turn begins.
    private mutating func show(_ events: inout [Event]) {
        let step = Self.interval(for: length), lead = Self.lead(for: length)
        while hops < length, clock >= Double(hops) * step {
            events.append(.hop(rune: sequence[hops], index: hops))
            hops += 1
        }
        while lights < length, clock >= Double(lights) * step + lead {
            glow[sequence[lights]] = 1
            events.append(.light(rune: sequence[lights], index: lights))
            lights += 1
        }
        if lights == length, clock >= Double(length - 1) * step + lead + step {
            phase = .repeating
            position = 0
            idle = 0
            hinted = nil
            events.append(.yourTurn(length: length))
        }
    }

    private mutating func startWatching() {
        phase = .watching
        clock = -0.6
        hops = 0
        lights = 0
        position = 0
        hinted = nil
    }

    // MARK: Taps

    /// The player taps a rune. Taps outside their turn are ignored.
    public mutating func tap(_ rune: Int) -> [Event] {
        guard phase == .repeating, (0..<Self.runes).contains(rune), position < sequence.count else { return [] }
        idle = 0
        hinted = nil
        glow[rune] = 1
        var events: [Event] = []
        let want = sequence[position]
        guard rune == want else {
            mistakes += 1
            levelClean = false
            streak = 0
            if !isLesson { lives -= 1 }
            events.append(.mistake(rune: rune, expected: want, livesLeft: lives))
            if lives <= 0 { finish(&events) } else { breathe(1.5) }
            return events
        }
        events.append(.tapped(rune: rune, index: position))
        if !isLesson { score += 1 }
        position += 1
        if position == sequence.count { complete(&events) }
        return events
    }

    private mutating func complete(_ events: inout [Event]) {
        if isLesson {
            isLesson = false
            phase = .rules
            clock = -0.9
            events.append(.cleared(length: length, points: 0, clean: levelClean, streak: 0, gainedLife: false))
            events.append(.rules)
            return
        }
        level = max(level, length)
        streak = levelClean ? streak + 1 : 0
        let points = length * (levelClean ? 2 : 1)
        score += points
        var gained = false
        if levelClean, length % 5 == 0, lives < Self.lives { lives += 1; gained = true }
        events.append(.cleared(length: length, points: points, clean: levelClean, streak: streak, gainedLife: gained))
        if length >= Self.longest {
            completed = true
            finish(&events)
            return
        }
        sequence.append(Self.next(after: sequence, from: &rng))
        levelClean = true
        breathe(1.2)
    }

    private mutating func breathe(_ seconds: Double) {
        phase = .between
        breath = seconds
    }

    private mutating func finish(_ events: inout [Event]) {
        phase = .over
        events.append(.finished)
    }

    /// Ends the round now (the player is done): what was earned stands.
    public mutating func stop() -> [Event] {
        guard phase != .over else { return [] }
        var events: [Event] = []
        isLesson = false
        finish(&events)
        return events
    }

    // MARK: Lesson and start

    /// Skips ahead: from the guided step, or the rules, to the countdown.
    public mutating func nextStep() -> [Event] {
        var events: [Event] = []
        if isLesson || phase == .rules {
            isLesson = false
            startCountdown(&events)
        }
        return events
    }

    private mutating func startCountdown(_ events: inout [Event]) {
        phase = .countdown
        clock = 0
        countdown = 3
        glow = [Double](repeating: 0, count: Self.runes)
        events.append(.countdown)
        events.append(.tick(3))
    }

    /// The real round starts from nothing: one rune to repeat.
    private mutating func begin() {
        score = 0
        lives = Self.lives
        mistakes = 0
        streak = 0
        level = 0
        levelClean = true
        sequence = Self.draw(count: 1, from: &rng)
        startWatching()
    }

    // MARK: Drawing runes

    private static func draw(count: Int, from rng: inout EchoRandom) -> [Int] {
        var out: [Int] = []
        for _ in 0..<count { out.append(next(after: out, from: &rng)) }
        return out
    }

    /// A random rune, never a third in a row.
    private static func next(after sequence: [Int], from rng: inout EchoRandom) -> Int {
        let rune = Int.random(in: 0..<runes, using: &rng)
        if sequence.count >= 2, sequence[sequence.count - 1] == rune, sequence[sequence.count - 2] == rune {
            return (rune + 1 + Int.random(in: 0..<(runes - 1), using: &rng)) % runes
        }
        return rune
    }
}
