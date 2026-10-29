import Foundation

/// One beat of an animation as data: hold a pose for a while. The same vocabulary every built-in
/// animation is written in (see the app's `Antics`), so any of them can be opened, changed and
/// shared, and new ones can do anything the built-in ones do.
public struct AnimationBeat: Codable, Hashable, Sendable {
    public var duration: Double
    /// Where the face turns, −1…1 each way (x right +, y down +). Nil: the mood decides (moods
    /// that watch the cursor keep doing so).
    public var lookX: Double?
    public var lookY: Double?
    /// A mood name (`AnimationBeat.moods`). Nil: whatever it's feeling anyway.
    public var mood: String?
    /// A little symbol above its head (`AnimationBeat.glyphs`).
    public var glyph: String?
    /// Degrees, + leans right.
    public var tilt: Double
    /// Hop when this beat starts.
    public var hop: Bool
    /// Body shape: + stands tall and thin, − squishes flat.
    public var stretch: Double
    /// A move played across the whole beat (`AnimationBeat.moves`): a spin round its own axis, a
    /// somersault, a cartwheel, bounces, a shake… Nil: it holds still.
    public var move: String?
    /// How many times the move goes (turns, bounces, shakes), 1…8. Nil: the move's usual count.
    public var times: Int?
    /// The move goes the other way (spins left, flips backwards, sways left first).
    public var reverse: Bool?

    public init(duration: Double, lookX: Double? = nil, lookY: Double? = nil, mood: String? = nil, glyph: String? = nil,
                tilt: Double = 0, hop: Bool = false, stretch: Double = 0, move: String? = nil, times: Int? = nil, reverse: Bool? = nil) {
        self.duration = duration; self.lookX = lookX; self.lookY = lookY; self.mood = mood; self.glyph = glyph
        self.tilt = tilt; self.hop = hop; self.stretch = stretch; self.move = move; self.times = times; self.reverse = reverse
    }

    public var hasLook: Bool { lookX != nil || lookY != nil }

    /// How many times its move goes (the move's usual count when not set).
    public var repeats: Int { times ?? move.map(Self.defaultTimes) ?? 1 }

    /// Moods a beat can show (the app's `Mood` cases).
    public static let moods = ["idle", "happy", "love", "content", "giggly", "excited", "surprised", "curious", "thinking",
                               "shy", "sad", "scared", "bored", "sleepy", "annoyed", "mean", "dizzy", "error", "listening", "working"]
    /// Symbols a beat can pop above the head.
    public static let glyphs = ["notes", "question", "exclaim", "idea", "sweat", "heart", "sparkles"]
    /// Moves a beat can play across its length: spin round its own axis, a somersault, a cartwheel,
    /// bounces, a shake, a sway, a jelly wobble, floating up, nods and a head shake.
    public static let moves = ["spin", "flip", "roll", "bounce", "shake", "sway", "wobble", "float", "nod", "headshake"]
    public static let timesRange = 1...8

    /// How many times a move goes when it's first picked.
    public static func defaultTimes(_ move: String) -> Int {
        switch move {
        case "bounce", "wobble": 3
        case "shake": 4
        case "sway", "float", "nod", "headshake": 2
        default: 1
        }
    }

    public static let durationRange = 0.05...6.0
    public static let tiltRange = -30.0...30.0
    public static let stretchRange = -0.3...0.3

    /// Within the limits a beat can be drawn with (files and models may say anything).
    public var normalized: AnimationBeat {
        var b = self
        b.duration = Self.clamp(duration.isFinite ? duration : 0.5, Self.durationRange)
        b.lookX = lookX.map { Self.clamp($0.isFinite ? $0 : 0, -1...1) }
        b.lookY = lookY.map { Self.clamp($0.isFinite ? $0 : 0, -1...1) }
        if b.hasLook { b.lookX = b.lookX ?? 0; b.lookY = b.lookY ?? 0 }
        b.mood = mood.flatMap { Self.moods.contains($0) ? $0 : nil }
        b.glyph = glyph.flatMap { Self.glyphs.contains($0) ? $0 : nil }
        b.tilt = Self.clamp(tilt.isFinite ? tilt : 0, Self.tiltRange)
        b.stretch = Self.clamp(stretch.isFinite ? stretch : 0, Self.stretchRange)
        b.move = move.flatMap { Self.moves.contains($0) ? $0 : nil }
        if let m = b.move {
            let n = min(max(times ?? Self.defaultTimes(m), Self.timesRange.lowerBound), Self.timesRange.upperBound)
            b.times = n == Self.defaultTimes(m) ? nil : n
            b.reverse = reverse == true ? true : nil
        } else {
            b.times = nil
            b.reverse = nil
        }
        return b
    }

    static func clamp(_ x: Double, _ r: ClosedRange<Double>) -> Double { min(max(x, r.lowerBound), r.upperBound) }
}

/// An animation someone made: a new one with a name of its own, or a new version of a built-in
/// one (`replaces`). Kept for every Imp (`ImpPreferences.animationLibrary`) or for one Imp alone
/// (`ImpProfile.animations`), where it wins over the shared one.
public struct MadeAnimation: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var about: String
    /// An SF Symbol for the list.
    public var symbol: String
    /// The built-in animation this one plays instead of. Nil: an animation of its own.
    public var replaces: Reaction?
    /// What starts it (only for an animation of its own: a replacement keeps the built-in one's starts).
    public var triggers: Set<AnimationTrigger>
    public var isEnabled: Bool
    public var beats: [AnimationBeat]

    public init(id: UUID = UUID(), name: String, about: String = "", symbol: String = MadeAnimation.defaultSymbol,
                replaces: Reaction? = nil, triggers: Set<AnimationTrigger> = [], isEnabled: Bool = true, beats: [AnimationBeat]) {
        self.id = id; self.name = name; self.about = about; self.symbol = symbol; self.replaces = replaces
        self.triggers = triggers; self.isEnabled = isEnabled; self.beats = beats
    }

    public static let defaultSymbol = "wand.and.stars"
    public static let maxBeats = 24
    public static let maxDuration = 20.0
    public static let maxName = 40

    public var duration: Double { beats.reduce(0) { $0 + $1.duration } }

    /// The name to show: its own, or the built-in one's it replaces.
    public var title: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (replaces?.title ?? String(localized: "Untitled")) : n
    }

    /// Symbols to pick from in the editor.
    public static let symbols = ["wand.and.stars", "sparkles", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "moon.zzz.fill",
                                 "music.note", "figure.dance", "hand.wave.fill", "face.smiling.inverse", "eyes", "cloud.rain.fill",
                                 "questionmark.circle.fill", "exclamationmark.circle.fill", "lightbulb.fill", "party.popper.fill",
                                 "tornado", "pawprint.fill", "theatermasks.fill", "crown.fill", "leaf.fill", "drop.fill", "zzz"]

    /// Within the limits (beats, lengths, names), whatever a file or a model said.
    public var normalized: MadeAnimation {
        var a = self
        a.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))
        a.about = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        if a.symbol.isEmpty { a.symbol = Self.defaultSymbol }
        a.beats = beats.prefix(Self.maxBeats).map(\.normalized)
        // Too long altogether: every beat shrinks alike, so the rhythm stays.
        let total = a.duration
        if total > Self.maxDuration {
            let k = Self.maxDuration / total
            a.beats = a.beats.map { var b = $0; b.duration = max(AnimationBeat.durationRange.lowerBound, b.duration * k); return b }
        }
        if a.replaces != nil { a.triggers = [] }
        return a
    }
}

/// What gives one Imp its own character in everything it does: heavy lids, a frown, big eyes,
/// droopy horns, a slower or quicker tempo. Laid over every mood and animation, and over the face
/// that follows the cursor.
public struct ImpTraits: Codable, Hashable, Sendable {
    /// Heavy lids (tired, unimpressed): 0…0.6.
    public var lids = 0.0
    /// Brows: − worried, + cross (−1…1).
    public var slant = 0.0
    /// Eye size: −0.4…0.4.
    public var eyes = 0.0
    /// One eye narrower than the other (−1…1).
    public var squint = 0.0
    /// Horns: − droopy, + perky (degrees, −30…30).
    public var horns = 0.0
    /// Rosy cheeks: 0…1.
    public var blush = 0.0
    /// Head cocked to one side (degrees, −12…12).
    public var tilt = 0.0
    /// How fast it acts: 0.6 slow and lazy … 1.6 quick and jittery.
    public var tempo = 1.0

    public init(lids: Double = 0, slant: Double = 0, eyes: Double = 0, squint: Double = 0, horns: Double = 0,
                blush: Double = 0, tilt: Double = 0, tempo: Double = 1) {
        self.lids = lids; self.slant = slant; self.eyes = eyes; self.squint = squint; self.horns = horns
        self.blush = blush; self.tilt = tilt; self.tempo = tempo
    }

    public static let plain = ImpTraits()
    public var isPlain: Bool { normalized == .plain }

    nonisolated(unsafe) public static let ranges: [WritableKeyPath<ImpTraits, Double>: ClosedRange<Double>] = [
        \.lids: 0...0.6, \.slant: -1...1, \.eyes: -0.4...0.4, \.squint: -1...1, \.horns: -30...30,
        \.blush: 0...1, \.tilt: -12...12, \.tempo: 0.6...1.6,
    ]

    public var normalized: ImpTraits {
        var t = self
        for (k, r) in Self.ranges { t[keyPath: k] = AnimationBeat.clamp(t[keyPath: k].isFinite ? t[keyPath: k] : 0, r) }
        if !tempo.isFinite { t.tempo = 1 }
        return t
    }

    /// Ready-made characters to start from.
    public struct Preset: Identifiable, Sendable {
        public let id: String
        public let emoji: String
        public let traits: ImpTraits
        public var name: String {
            switch id {
            case "plain": String(localized: "Plain")
            case "tired": String(localized: "Tired")
            case "grumpy": String(localized: "Grumpy")
            case "worried": String(localized: "Worried")
            case "wide": String(localized: "Wide-eyed")
            case "sly": String(localized: "Sly")
            case "sweet": String(localized: "Sweet")
            case "lazy": String(localized: "Lazy")
            case "jittery": String(localized: "Jittery")
            default: id
            }
        }
    }

    public static let presets: [Preset] = [
        Preset(id: "plain", emoji: "🙂", traits: .plain),
        Preset(id: "tired", emoji: "😪", traits: ImpTraits(lids: 0.38, slant: -0.15, eyes: -0.05, horns: -10, tempo: 0.85)),
        Preset(id: "grumpy", emoji: "😠", traits: ImpTraits(lids: 0.3, slant: 0.55, horns: 6)),
        Preset(id: "worried", emoji: "😟", traits: ImpTraits(slant: -0.6, eyes: 0.06, horns: -14, tilt: -3)),
        Preset(id: "wide", emoji: "😳", traits: ImpTraits(eyes: 0.22, horns: 10, tempo: 1.1)),
        Preset(id: "sly", emoji: "😏", traits: ImpTraits(lids: 0.22, slant: 0.2, squint: 0.55, tilt: 5)),
        Preset(id: "sweet", emoji: "🥰", traits: ImpTraits(eyes: 0.08, horns: 4, blush: 0.7, tilt: 4)),
        Preset(id: "lazy", emoji: "🦥", traits: ImpTraits(lids: 0.28, horns: -8, tempo: 0.65)),
        Preset(id: "jittery", emoji: "⚡️", traits: ImpTraits(slant: -0.2, eyes: 0.12, horns: 12, tempo: 1.45)),
    ]

    /// The preset these traits are (nil: someone's own mix).
    public var preset: Preset? { Self.presets.first { $0.traits == normalized } }

    /// A few words for a list ("Heavy lids, worried brows, slow").
    public var summary: String {
        let t = normalized
        var parts: [String] = []
        if t.lids >= 0.15 { parts.append(String(localized: "heavy lids")) }
        if t.slant >= 0.2 { parts.append(String(localized: "cross brows")) } else if t.slant <= -0.2 { parts.append(String(localized: "worried brows")) }
        if t.eyes >= 0.1 { parts.append(String(localized: "big eyes")) } else if t.eyes <= -0.1 { parts.append(String(localized: "small eyes")) }
        if abs(t.squint) >= 0.25 { parts.append(String(localized: "a squint")) }
        if t.horns >= 8 { parts.append(String(localized: "perky horns")) } else if t.horns <= -8 { parts.append(String(localized: "droopy horns")) }
        if t.blush >= 0.3 { parts.append(String(localized: "rosy cheeks")) }
        if abs(t.tilt) >= 3 { parts.append(String(localized: "a cocked head")) }
        if t.tempo <= 0.85 { parts.append(String(localized: "slow")) } else if t.tempo >= 1.2 { parts.append(String(localized: "quick")) }
        guard let first = parts.first else { return String(localized: "Plain") }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", ")
    }
}

/// Something that can be played: a built-in animation, or one someone made.
public enum AnimationRef: Hashable, Sendable {
    case preset(Reaction)
    case custom(UUID)

    /// Stable text for it (what's playing, cooldowns).
    public var key: String {
        switch self {
        case .preset(let r): r.rawValue
        case .custom(let id): "custom-\(id.uuidString)"
        }
    }

    public var preset: Reaction? { if case .preset(let r) = self { r } else { nil } }
}

// MARK: - The library

extension ImpPreferences {
    /// Animations someone made for every Imp: new ones and new versions of built-in ones.
    public var animationLibrary: [MadeAnimation] {
        get { customAnimations ?? [] }
        set { customAnimations = newValue.isEmpty ? nil : newValue }
    }

    /// One Imp's own animations (empty for nil or an Imp that isn't there).
    public func ownAnimations(of imp: UUID?) -> [MadeAnimation] {
        imp.flatMap { id in imps.first { $0.id == id } }?.animations ?? []
    }

    /// The animation that plays for `reaction` on `imp`: the Imp's own version, else the shared
    /// one, else nil (the built-in one).
    public func replacement(for reaction: Reaction, imp: UUID?) -> MadeAnimation? {
        ownAnimations(of: imp).first { $0.replaces == reaction } ?? animationLibrary.first { $0.replaces == reaction }
    }

    /// A made animation by id: the Imp's own first, then the shared ones.
    public func customAnimation(_ id: UUID, imp: UUID?) -> MadeAnimation? {
        ownAnimations(of: imp).first { $0.id == id } ?? animationLibrary.first { $0.id == id }
    }

    /// Whether `ref` may play on `imp` at all (switched on; a missing one can't).
    public func isEnabled(_ ref: AnimationRef, imp: UUID?) -> Bool {
        switch ref {
        case .preset(let r): isEnabled(r)
        case .custom(let id): customAnimation(id, imp: imp)?.isEnabled ?? false
        }
    }

    /// New animations (not replacements) `imp` has: its own first, then the shared ones.
    public func originals(for imp: UUID?) -> [MadeAnimation] {
        (ownAnimations(of: imp) + animationLibrary).filter { $0.replaces == nil }
    }

    /// What `trigger` may start on `imp`, in priority order: its own animations, the shared ones, then the built-in.
    public func refs(for trigger: AnimationTrigger, imp: UUID?) -> [AnimationRef] {
        let made = originals(for: imp).filter { $0.isEnabled && $0.triggers.contains(trigger) }.map { AnimationRef.custom($0.id) }
        return made + animations(for: trigger).map { .preset($0) }
    }

    /// The one animation a gesture starts on `imp` (an Imp's own wins over the shared ones).
    public func ref(for trigger: AnimationTrigger, imp: UUID?) -> AnimationRef? {
        refs(for: trigger, imp: imp).first
    }

    /// Whether some made animation is started by the cursor (see `watchesCursor`).
    var madeAnimationsWatchCursor: Bool {
        (animationLibrary + imps.flatMap(\.animations)).contains { a in
            a.replaces == nil && a.isEnabled && a.triggers.contains { $0.watchesCursor }
        }
    }

    /// Adds `animation` (or updates the one with its id) for `imp`, or for every Imp (nil). A
    /// replacement takes the place of any other replacement of the same built-in one there.
    public mutating func save(_ animation: MadeAnimation, for imp: UUID?) {
        let a = animation.normalized
        func put(_ list: inout [MadeAnimation]) {
            if let r = a.replaces { list.removeAll { $0.replaces == r && $0.id != a.id } }
            if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a } else { list.append(a) }
        }
        if let imp, let i = imps.firstIndex(where: { $0.id == imp }) {
            // It moved here from the shared list (or the other way): only one place has it.
            animationLibrary.removeAll { $0.id == a.id }
            put(&imps[i].animations)
        } else {
            for i in imps.indices { imps[i].animations.removeAll { $0.id == a.id } }
            var list = animationLibrary
            put(&list)
            animationLibrary = list
            if a.isEnabled { claimGestures(of: a) }
        }
    }

    /// Removes a made animation, wherever it is (the built-in one it replaced plays again).
    public mutating func removeAnimation(_ id: UUID) {
        animationLibrary.removeAll { $0.id == id }
        for i in imps.indices { imps[i].animations.removeAll { $0.id == id } }
    }

    /// Who has it: an Imp's id, nil for every Imp. `.none` when it isn't anywhere.
    public func owner(ofAnimation id: UUID) -> UUID?? {
        if animationLibrary.contains(where: { $0.id == id }) { return .some(nil) }
        if let imp = imps.first(where: { $0.animations.contains { $0.id == id } }) { return .some(imp.id) }
        return .none
    }

    /// Switches a made animation on or off.
    public mutating func setEnabled(_ on: Bool, animation id: UUID) {
        guard let owner = owner(ofAnimation: id), var a = customAnimation(id, imp: owner) else { return }
        a.isEnabled = on
        save(a, for: owner)
    }

    /// Adds or removes what starts a made animation. A gesture starts one animation: given to a
    /// shared one it moves there from wherever it was; given to an Imp's own, it moves from that
    /// Imp's other ones (and wins over the shared one for that Imp).
    public mutating func setTrigger(_ trigger: AnimationTrigger, _ on: Bool, animation id: UUID) {
        guard let owner = owner(ofAnimation: id), var a = customAnimation(id, imp: owner), a.replaces == nil else { return }
        if on { a.triggers.insert(trigger) } else { a.triggers.remove(trigger) }
        if on && trigger.isExclusive, let imp = owner, let i = imps.firstIndex(where: { $0.id == imp }) {
            for j in imps[i].animations.indices where imps[i].animations[j].id != id { imps[i].animations[j].triggers.remove(trigger) }
        }
        save(a, for: owner)
    }

    /// A shared animation that holds gestures takes them from the built-in ones and the other shared ones.
    private mutating func claimGestures(of a: MadeAnimation) {
        for trigger in a.triggers where trigger.isExclusive {
            for r in Reaction.allCases where rule(for: r).triggers.contains(trigger) {
                var rule = rule(for: r)
                rule.triggers.remove(trigger)
                store(rule, for: r)
            }
            var list = animationLibrary
            for j in list.indices where list[j].id != a.id { list[j].triggers.remove(trigger) }
            animationLibrary = list
        }
    }

    /// A built-in gesture given to a built-in animation leaves the shared made ones.
    mutating func releaseGesture(_ trigger: AnimationTrigger) {
        guard trigger.isExclusive, animationLibrary.contains(where: { $0.triggers.contains(trigger) }) else { return }
        var list = animationLibrary
        for j in list.indices { list[j].triggers.remove(trigger) }
        animationLibrary = list
    }

    /// A made animation by name (or a built-in one by its id or title), as the Imp's tools take them.
    public func ref(named name: String, imp: UUID?) -> AnimationRef? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = originals(for: imp).first(where: { $0.title.caseInsensitiveCompare(n) == .orderedSame }) { return .custom(a.id) }
        if let r = Reaction.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(n) == .orderedSame || $0.title.caseInsensitiveCompare(n) == .orderedSame }) {
            return .preset(r)
        }
        return nil
    }

    /// A name for a new animation nobody of `imp` (or the shared list) uses yet.
    public func uniqueAnimationName(_ name: String, imp: UUID?, except id: UUID? = nil) -> String {
        let used = (ownAnimations(of: imp) + animationLibrary).filter { $0.id != id }.map(\.title) + Reaction.allCases.map(\.title)
        return ImpProfile.uniqueName(name.isEmpty ? String(localized: "My animation") : name, avoiding: used)
    }
}

extension ImpProfile {
    /// Its own animations: new ones only it plays, and its own versions of built-in ones.
    public var animations: [MadeAnimation] {
        get { ownAnimations ?? [] }
        set { ownAnimations = newValue.isEmpty ? nil : newValue }
    }

    /// Its character, laid over everything it does.
    public var traits: ImpTraits {
        get { character ?? .plain }
        set { character = newValue.isPlain ? nil : newValue.normalized }
    }
}

// MARK: - Kits

extension AnimationBeat {
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["duration": .number(Self.round(duration))]
        if hasLook { o["look"] = .array([.number(Self.round(lookX ?? 0)), .number(Self.round(lookY ?? 0))]) }
        if let mood { o["mood"] = .string(mood) }
        if let glyph { o["glyph"] = .string(glyph) }
        if tilt != 0 { o["tilt"] = .number(Self.round(tilt)) }
        if hop { o["hop"] = .bool(true) }
        if stretch != 0 { o["stretch"] = .number(Self.round(stretch)) }
        if let move {
            o["move"] = .string(move)
            if let times { o["times"] = .number(Double(times)) }
            if reverse == true { o["reverse"] = .bool(true) }
        }
        return .object(o)
    }

    static func round(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    /// A beat from a kit or a tool call. Nil without a duration; unknown moods and glyphs are reported and left out.
    init?(kit json: JSONValue, problems: inout [String]) {
        guard case .object = json, let duration = json["duration"]?.double else {
            problems.append(String(localized: "A beat needs a `duration` in seconds."))
            return nil
        }
        var look: (Double, Double)?
        if let pair = json["look"]?.array, pair.count == 2, let x = pair[0].double, let y = pair[1].double { look = (x, y) }
        else if let x = json["lookX"]?.double ?? json["look"]?["x"]?.double, let y = json["lookY"]?.double ?? json["look"]?["y"]?.double { look = (x, y) }
        let mood = json["mood"]?.string?.lowercased()
        if let mood, !Self.moods.contains(mood) { problems.append(String(localized: "Unknown mood “\(mood)”.")) }
        let glyph = json["glyph"]?.string?.lowercased()
        if let glyph, !Self.glyphs.contains(glyph) { problems.append(String(localized: "Unknown glyph “\(glyph)”.")) }
        let move = json["move"]?.string?.lowercased()
        if let move, !Self.moves.contains(move) { problems.append(String(localized: "Unknown move “\(move)”.")) }
        // Clamped before it becomes an Int: a huge number in a file must not trap.
        let times = json["times"]?.double.flatMap { $0.isFinite ? Int(min(max($0, -100), 100).rounded()) : nil }
        self = AnimationBeat(duration: duration, lookX: look?.0, lookY: look?.1, mood: mood, glyph: glyph,
                             tilt: json["tilt"]?.double ?? 0, hop: json["hop"]?.bool ?? false,
                             stretch: json["stretch"]?.double ?? 0, move: move, times: times,
                             reverse: json["reverse"]?.bool).normalized
    }
}

extension MadeAnimation {
    /// An animation as it's written in a kit (no id: it gets a new one wherever it lands).
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "beats": .array(beats.map(\.kitJSON))]
        if !about.isEmpty { o["about"] = .string(about) }
        if symbol != Self.defaultSymbol { o["symbol"] = .string(symbol) }
        if let replaces { o["replaces"] = .string(replaces.rawValue) }
        if !triggers.isEmpty { o["starts"] = .array(AnimationTrigger.allCases.filter(triggers.contains).map { .string($0.rawValue) }) }
        if !isEnabled { o["enabled"] = .bool(false) }
        return .object(o)
    }

    /// An animation from a kit or a tool call. Nil (with the reason in `problems`) when it can't be played.
    public init?(kit json: JSONValue, problems: inout [String]) {
        guard case .object = json else { problems.append(String(localized: "Should be an object.")); return nil }
        var replaces: Reaction?
        if let r = json["replaces"]?.string, !r.isEmpty {
            guard let reaction = Reaction.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(r) == .orderedSame }) else {
                problems.append(String(localized: "Replaces “\(r)”, which isn't a built-in animation."))
                return nil
            }
            replaces = reaction
        }
        let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty || replaces != nil else { problems.append(String(localized: "Needs a name.")); return nil }
        guard let list = json["beats"]?.array, !list.isEmpty else { problems.append(String(localized: "Needs `beats`.")); return nil }
        let beats = list.compactMap { AnimationBeat(kit: $0, problems: &problems) }
        guard !beats.isEmpty else { return nil }
        if list.count > Self.maxBeats { problems.append(String(localized: "Only the first \(Self.maxBeats) beats are kept.")) }
        var triggers: Set<AnimationTrigger> = []
        for case .string(let s) in json["starts"]?.array ?? [] {
            if let t = AnimationTrigger(rawValue: s) { triggers.insert(t) } else { problems.append(String(localized: "Unknown start “\(s)”.")) }
        }
        self = MadeAnimation(name: name, about: json["about"]?.string ?? "",
                               symbol: json["symbol"]?.string ?? Self.defaultSymbol, replaces: replaces, triggers: triggers,
                               isEnabled: json["enabled"]?.bool ?? true, beats: beats).normalized
    }
}

extension MadeAnimation {
    /// A list of animations from a kit; what can't be read goes to `problems`, labelled.
    static func read(_ list: [JSONValue], problems: inout [String]) -> [MadeAnimation] {
        var out: [MadeAnimation] = []
        for (i, item) in list.enumerated() {
            var mine: [String] = []
            let label = item["name"]?.string.map { String(localized: "Animation \(i + 1) (“\($0)”)") } ?? String(localized: "Animation \(i + 1)")
            if let a = MadeAnimation(kit: item, problems: &mine) { out.append(a) }
            problems += mine.map { "\(label): \($0)" }
        }
        return out
    }
}

extension ImpTraits {
    var kitJSON: JSONValue {
        let t = normalized
        var o: [String: JSONValue] = [:]
        let names: [(String, KeyPath<ImpTraits, Double>, Double)] = [("lids", \.lids, 0), ("slant", \.slant, 0), ("eyes", \.eyes, 0),
                                                                     ("squint", \.squint, 0), ("horns", \.horns, 0), ("blush", \.blush, 0),
                                                                     ("tilt", \.tilt, 0), ("tempo", \.tempo, 1)]
        for (key, path, plain) in names where t[keyPath: path] != plain { o[key] = .number(AnimationBeat.round(t[keyPath: path])) }
        return .object(o)
    }

    init(kit json: JSONValue) {
        self = ImpTraits(lids: json["lids"]?.double ?? 0, slant: json["slant"]?.double ?? 0, eyes: json["eyes"]?.double ?? 0,
                         squint: json["squint"]?.double ?? 0, horns: json["horns"]?.double ?? 0, blush: json["blush"]?.double ?? 0,
                         tilt: json["tilt"]?.double ?? 0, tempo: json["tempo"]?.double ?? 1).normalized
    }
}

// The kit form, for the app's tools (what an Imp is shown of an animation, or of itself).
extension AnimationBeat { public var kitJSONValue: JSONValue { kitJSON } }
extension ImpTraits { public var kitJSONValue: JSONValue { kitJSON } }
extension MadeAnimation { public var kitJSONValue: JSONValue { kitJSON } }
