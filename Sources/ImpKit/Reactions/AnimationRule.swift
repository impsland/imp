import Foundation

/// What can start an animation.
public enum AnimationTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    /// On its own, when the mouse has been still for a while.
    case idle
    /// Four quick clicks on the Imp.
    case poke
    /// Circling the cursor around the Imp.
    case circle
    /// Swishing the cursor left-right-left in front of its face.
    case swish
    /// Gently stroking the top of its head with the cursor.
    case stroke
    /// You picked its favourite colour.
    case favoriteColor
    /// Quick little jiggles of the cursor on its head.
    case tickle
    /// Pressing and holding on it without moving.
    case hold
    /// Dragging it somewhere.
    case pickUp
    /// Shaking it back and forth while you drag it.
    case shake
    /// Letting go after a drag.
    case drop
    /// The cursor rushing at it from afar.
    case rush
    /// The cursor resting beside it for a while.
    case linger
    /// The cursor resting right on its face.
    case stare
    /// Bobbing the cursor up and down above its head.
    case dangle
    /// Coming back to the mouse after a minute away.
    case comeback

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .idle: "When it's quiet"
        case .poke: "4 quick clicks"
        case .circle: "Circle it with the cursor"
        case .swish: "Swish past its face"
        case .stroke: "Stroke its head"
        case .favoriteColor: "Its favourite colour"
        case .tickle: "Tickle it"
        case .hold: "Press and hold it"
        case .pickUp: "Carry it"
        case .shake: "Shake it while carrying"
        case .drop: "Put it down"
        case .rush: "Rush at it"
        case .linger: "Rest the cursor beside it"
        case .stare: "Rest the cursor on its face"
        case .dangle: "Bob the cursor above it"
        case .comeback: "Come back after a break"
        }
    }

    public var symbol: String {
        switch self {
        case .idle: "hourglass"
        case .poke: "cursorarrow.click.2"
        case .circle: "arrow.triangle.2.circlepath"
        case .swish: "arrow.left.and.right"
        case .stroke: "hand.draw"
        case .favoriteColor: "paintpalette"
        case .tickle: "hand.point.up.fill"
        case .hold: "hand.tap.fill"
        case .pickUp: "hand.raised.fingers.spread.fill"
        case .shake: "iphone.radiowaves.left.and.right"
        case .drop: "arrow.down.circle"
        case .rush: "hare.fill"
        case .linger: "cursorarrow.rays"
        case .stare: "eye"
        case .dangle: "arrow.up.and.down"
        case .comeback: "door.left.hand.open"
        }
    }

    /// A gesture starts exactly one animation (assigning it elsewhere moves it), so it's always
    /// predictable. Quiet moments can start many (one is picked).
    public var isExclusive: Bool { self != .idle }

    /// Whether it comes from watching the cursor go by (the "Mouse games" switch), rather than
    /// from clicking, pressing or carrying the Imp, which it always notices.
    public var watchesCursor: Bool {
        switch self {
        case .circle, .swish, .stroke, .tickle, .rush, .linger, .stare, .dangle, .comeback: true
        case .idle, .poke, .favoriteColor, .hold, .pickUp, .shake, .drop: false
        }
    }
}

/// Whether an animation plays, and what starts it.
public struct AnimationRule: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var triggers: Set<AnimationTrigger>

    public init(isEnabled: Bool = true, triggers: Set<AnimationTrigger>) {
        self.isEnabled = isEnabled
        self.triggers = triggers
    }
}

extension Reaction {
    /// The out-of-the-box triggers. Expressions and gestures start with none: the troupe uses
    /// some to respond to each other, and you can give any of them a trigger.
    public var defaultTriggers: Set<AnimationTrigger> {
        switch self {
        case .smile, .love: [.idle]
        case .greet, .bye, .thanks, .sleep, .jump, .laugh, .sad, .wow: []
        case .dizzy: [.circle]
        case .mean: [.swish]
        case .pet: [.stroke]
        case .angry: [.poke]
        case .delight: [.favoriteColor]
        case .giggle: [.tickle]
        case .cuddle: [.hold]
        case .wheee: [.pickUp]
        case .woozy: [.shake]
        case .plop: [.drop]
        case .flinch: [.rush]
        case .curious: [.linger]
        case .shy: [.stare]
        case .pounce: [.dangle]
        case .missedYou: [.comeback]
        case .boo, .shiver, .blowKiss, .proud: []
        case .glance, .hum, .idea, .lookAround, .turn, .showOff, .wonder, .nap, .watch,
             .dance, .yawn, .sneeze, .peekaboo, .stargaze, .bored: [.idle]
        case .yes, .no, .maybe, .dontKnow, .areYouSure, .notSure, .exactly, .nope, .hmm, .aha,
             .tada, .sorry, .oops, .impressed, .haha, .loveIt, .sadNews, .careful, .welcome, .confused: []
        }
    }

    /// How often it's picked among the routines for a quiet moment (higher = more often).
    public var idleWeight: Int {
        switch self {
        case .glance, .lookAround, .hum, .watch, .smile: 2
        default: 1
        }
    }

    /// Groups for the settings list.
    public enum Family: String, CaseIterable, Sendable {
        case expressions, gestures, play, handling, routines
    }

    public var family: Family {
        switch self {
        case .greet, .jump, .smile, .love, .laugh, .sad, .wow, .sleep, .thanks, .bye,
             .boo, .shiver, .blowKiss, .proud: .expressions
        case .dizzy, .mean, .pet, .angry, .delight: .play
        case .giggle, .cuddle, .wheee, .woozy, .plop, .flinch, .curious, .shy, .pounce, .missedYou: .handling
        case .glance, .lookAround, .turn, .hum, .showOff, .wonder, .idea, .nap, .watch,
             .dance, .yawn, .sneeze, .peekaboo, .stargaze, .bored: .routines
        case .yes, .no, .maybe, .dontKnow, .areYouSure, .notSure, .exactly, .nope, .hmm, .aha,
             .tada, .sorry, .oops, .impressed, .haha, .loveIt, .sadNews, .careful, .welcome, .confused: .gestures
        }
    }
}

extension ImpPreferences {
    /// An animation's rule: the user's, or the default.
    public func rule(for reaction: Reaction) -> AnimationRule {
        animations[reaction] ?? AnimationRule(triggers: reaction.defaultTriggers)
    }

    /// Switched-on animations a trigger may start, in catalogue order.
    public func animations(for trigger: AnimationTrigger) -> [Reaction] {
        Reaction.allCases.filter { let r = rule(for: $0); return r.isEnabled && r.triggers.contains(trigger) }
    }

    /// The one animation a gesture starts (nil if none is assigned, or it's switched off).
    public func animation(for trigger: AnimationTrigger) -> Reaction? {
        animations(for: trigger).first
    }

    /// Whether an animation may play at all (previews, troupe responses).
    public func isEnabled(_ reaction: Reaction) -> Bool { rule(for: reaction).isEnabled }

    public mutating func setEnabled(_ on: Bool, for reaction: Reaction) {
        var r = rule(for: reaction)
        r.isEnabled = on
        store(r, for: reaction)
    }

    /// Adds or removes a trigger. An exclusive trigger (a gesture) moves here from wherever it was.
    public mutating func setTrigger(_ trigger: AnimationTrigger, _ on: Bool, for reaction: Reaction) {
        if on && trigger.isExclusive {
            for other in Reaction.allCases where other != reaction && rule(for: other).triggers.contains(trigger) {
                var r = rule(for: other)
                r.triggers.remove(trigger)
                store(r, for: other)
            }
        }
        var r = rule(for: reaction)
        if on { r.triggers.insert(trigger) } else { r.triggers.remove(trigger) }
        store(r, for: reaction)
    }

    /// Every animation back to how it came.
    public mutating func resetAnimations() { animations = [:] }

    /// Keeps only real changes, so defaults can evolve for animations the user never touched.
    private mutating func store(_ rule: AnimationRule, for reaction: Reaction) {
        animations[reaction] = rule == AnimationRule(triggers: reaction.defaultTriggers) ? nil : rule
    }
}
