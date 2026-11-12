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
        case .idle: String(localized: "When it's quiet")
        case .poke: String(localized: "4 quick clicks")
        case .circle: String(localized: "Circle it with the cursor")
        case .swish: String(localized: "Swish past its face")
        case .stroke: String(localized: "Stroke its head")
        case .favoriteColor: String(localized: "Its favourite colour")
        case .tickle: String(localized: "Tickle it")
        case .hold: String(localized: "Press and hold it")
        case .pickUp: String(localized: "Carry it")
        case .shake: String(localized: "Shake it while carrying")
        case .drop: String(localized: "Put it down")
        case .rush: String(localized: "Rush at it")
        case .linger: String(localized: "Rest the cursor beside it")
        case .stare: String(localized: "Rest the cursor on its face")
        case .dangle: String(localized: "Bob the cursor above it")
        case .comeback: String(localized: "Come back after a break")
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

    /// Whether it comes from watching the cursor go by (the cursor monitor, see `ImpPreferences.watchesCursor`), rather than
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

/// The rules the user changed, by animation. Kept as a list of key and rule pairs, as it always was;
/// a rule for an animation the app no longer carries (the old built-in ones now come from the Den) is dropped on reading.
public struct AnimationRules: Codable, Hashable, Sendable, ExpressibleByDictionaryLiteral {
    private var rules: [Reaction: AnimationRule] = [:]

    public init(dictionaryLiteral elements: (Reaction, AnimationRule)...) {
        for (key, rule) in elements { rules[key] = rule }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public subscript(reaction: Reaction) -> AnimationRule? {
        get { rules[reaction] }
        set { rules[reaction] = newValue }
    }

    public init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        while !list.isAtEnd {
            let key = try list.decode(String.self)
            let rule = try list.decode(AnimationRule.self)
            if let reaction = Reaction(rawValue: key) { rules[reaction] = rule }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var list = encoder.unkeyedContainer()
        for (key, rule) in rules.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try list.encode(key.rawValue)
            try list.encode(rule)
        }
    }
}

extension Reaction {
    /// The out-of-the-box triggers, as the catalog says: its `starts` and the gestures `defaults` gives it.
    public var defaultTriggers: Set<AnimationTrigger> {
        entry.starts.union(AnimationCatalog.defaults.filter { $0.value == rawValue }.keys)
    }

    /// How often it's picked among the routines for a quiet moment (higher = more often).
    public var idleWeight: Int { self == .smile ? 2 : 1 }

    /// Groups for the settings list, by what an animation is for.
    public enum Family: String, CaseIterable, Sendable {
        /// Feelings it shows (and how Imps respond to each other).
        case expressions
        /// Body language for its answers: a nod, a shrug, a bow.
        case gestures
    }

    public var family: Family { self == .greet ? .gestures : .expressions }
}

extension ImpPreferences {
    /// An animation's rule: the user's, or the default.
    public func rule(for reaction: Reaction) -> AnimationRule {
        animations[reaction] ?? AnimationRule(triggers: reaction.defaultTriggers)
    }

    /// Whether the cursor needs watching at all: Mouse games is on and some switched-on animation
    /// is started by a cursor game. Nothing else needs the global mouse monitor.
    public var watchesCursor: Bool {
        mouseGames && (madeAnimationsWatchCursor || Reaction.allCases.contains { r in
            let rule = rule(for: r)
            return rule.isEnabled && rule.triggers.contains { $0.watchesCursor }
        })
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
            releaseGesture(trigger)
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

    /// Every built-in animation switched on again, with its original starts (made animations stay).
    public mutating func resetAnimations() { animations = [:] }

    /// Keeps only real changes, so defaults can evolve for animations the user never touched.
    mutating func store(_ rule: AnimationRule, for reaction: Reaction) {
        animations[reaction] = rule == AnimationRule(triggers: reaction.defaultTriggers) ? nil : rule
    }
}
