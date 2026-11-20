import Foundation

/// One step a trigger runs (`do`): an act, its value, and the extras that act takes. Steps run in
/// order and at once; `ask` hands its work to the Imp's model and the next steps don't wait for it.
public struct Step: Codable, Hashable, Sendable {
    public enum Act: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Hands the instruction (`value`) and what happened to the Imp's model. Needs a Brain.
        case ask
        /// Shows `value` in the bubble. No Brain needed.
        case say
        /// Plays the animation named `value`.
        case play
        /// Falls asleep, playing the animation named `value` (optional) doing it.
        case sleep
        /// Wakes up, playing the animation named `value` (optional) doing it.
        case wake
        /// How the Imp follows the pointer from now on: `value` is off, eyes, hop or glide. Mac only.
        case follow
        /// Opens `value`: text_box, listen, chat or settings.
        case open

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .ask: String(localized: "trigger.step.ask")
            case .say: String(localized: "trigger.step.say")
            case .play: String(localized: "trigger.step.play")
            case .sleep: String(localized: "trigger.step.sleep")
            case .wake: String(localized: "trigger.step.wake")
            case .follow: String(localized: "trigger.step.follow")
            case .open: String(localized: "trigger.step.open")
            }
        }

        /// What it does, in a few more words: the tooltip of its tile.
        public var hint: String {
            switch self {
            case .ask: String(localized: "Ask the Imp")
            case .say: String(localized: "Say something")
            case .play: String(localized: "Play an animation")
            case .sleep: String(localized: "Fall asleep")
            case .wake: String(localized: "Wake up")
            case .follow: String(localized: "Follow the cursor")
            case .open: String(localized: "Open something")
            }
        }

        public var symbol: String {
            switch self {
            case .ask: "sparkles"
            case .say: "text.bubble"
            case .play: "play.circle"
            case .sleep: "moon.zzz"
            case .wake: "sun.max"
            case .follow: "cursorarrow.motionlines"
            case .open: "arrow.up.forward.app"
            }
        }

        /// Happens on the Imp's own body and runs without a brain.
        public var isLocal: Bool { self != .ask }

        /// `value` names an animation.
        public var usesAnimation: Bool { self == .play || self == .sleep || self == .wake }
    }

    /// What `open` can open.
    public enum Target: String, CaseIterable, Sendable, Identifiable {
        case textBox = "text_box", listen, chat, settings
        public var id: String { rawValue }
    }

    public var act: Act
    public var value: String?
    /// ask: hand over what the person copied.
    public var clipboard: Bool?
    /// follow: 0.5 to 2, 1 is normal.
    public var speed: Double?

    public init(_ act: Act, value: String? = nil, clipboard: Bool? = nil, speed: Double? = nil) {
        self.act = act; self.value = value; self.clipboard = clipboard
        self.speed = speed.map(FollowMath.clampedSpeed)
    }

    public static let maxPerTrigger = 5

    public var text: String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    /// play / sleep / wake: the animation's name, if one is given.
    public var animationName: String? { act.usesAnimation && !text.isEmpty ? text : nil }
    public var handsOverClipboard: Bool { clipboard == true }
    public var followMode: FollowMode { FollowMode(rawValue: text.lowercased()) ?? .eyes }
    public var followSpeed: Double { FollowMath.clampedSpeed(speed ?? FollowMath.defaultSpeed) }
    public var target: Target? { Target(rawValue: text.lowercased()) }

    /// Can run: an `ask` has something to send (what you copied, or an instruction), the others their value.
    public var isRunnable: Bool {
        switch act {
        case .ask: handsOverClipboard || !text.isEmpty
        case .say, .play: !text.isEmpty
        case .sleep, .wake: true
        case .follow: FollowMode(rawValue: text.lowercased()) != nil
        case .open: target != nil
        }
    }

    /// In a few words, for lists and for the model: "play Wiggle", "say “Ouch!”".
    public var summary: String {
        switch act {
        case .ask: text.isEmpty ? "ask (respond to it)" : "ask: \(text)" + (handsOverClipboard ? " (with the clipboard)" : "")
        case .say: "say “\(text)”"
        case .play, .sleep, .wake: act.rawValue + (text.isEmpty ? "" : " “\(text)”")
        case .follow: "follow \(followMode.rawValue)" + (followMode.movesBody ? String(format: " at %.1f×", followSpeed) : "")
        case .open: "open \(text)"
        }
    }
}

/// A trigger: **when this happens (and these hold), the Imp runs these steps.** The contract is
/// `docs/sharing/kits.md#triggers`; the same object is what kits and the Imp's own tool
/// `imp_add_trigger` use (see `TriggerJSON.swift`).
public struct Shortcut: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var isEnabled = true
    /// The keys, when the event is `.keys`.
    public var hotkey: Hotkey?
    /// Which Imp does this. `nil` = every Imp: the one you click, or else whichever you talked to last.
    public var performer: UUID?
    /// The shared trigger this one stands in for, for its `performer` alone (see `SettingScope`).
    /// `nil`: not a version of a shared one.
    public var overrides: UUID?
    /// What sets it off.
    public var trigger: Trigger
    /// What must also hold when it goes off.
    public var conditions: [Condition]
    /// What it does, in order: 1 to 5 steps.
    public var steps: [Step]

    public init(name: String, isEnabled: Bool = true, hotkey: Hotkey? = nil, performer: UUID? = nil,
                trigger: Trigger = .keys, conditions: [Condition] = [], steps: [Step]) {
        self.name = name; self.isEnabled = isEnabled; self.hotkey = hotkey; self.performer = performer
        self.trigger = trigger; self.conditions = conditions; self.steps = steps
    }

    /// Reads whatever is there and never throws, so one damaged trigger can't take the rest of the
    /// preferences with it: `ImpPreferences` drops the ones that aren't `isValid` when it loads.
    public init(from decoder: Decoder) throws {
        self.init(name: "", trigger: .keys, steps: [])
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? id
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        hotkey = try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        performer = try? c.decodeIfPresent(UUID.self, forKey: .performer)
        overrides = try? c.decodeIfPresent(UUID.self, forKey: .overrides)
        trigger = (try? c.decodeIfPresent(Trigger.self, forKey: .trigger)) ?? .keys
        conditions = (try? c.decodeIfPresent([Condition].self, forKey: .conditions)) ?? []
        steps = (try? c.decodeIfPresent([Step].self, forKey: .steps)) ?? []
    }

    /// Has what it needs to run: 1 to 5 steps, and keys if the event is keys.
    public var isValid: Bool {
        (1...Step.maxPerTrigger).contains(steps.count) && steps.allSatisfy(\.isRunnable) && (trigger.event != .keys || hotkey != nil)
    }

    /// The keys to listen for: set, and the event is keys.
    public var keys: Hotkey? { trigger.event == .keys ? hotkey : nil }

    /// Every step happens on the Imp's own body, so it runs without a brain.
    public var runsLocally: Bool { steps.allSatisfy { $0.act.isLocal } }

    /// The first `ask` step, if any.
    public var askStep: Step? { steps.first { $0.act == .ask } }

    /// How its last `follow` step makes the Imp follow the pointer, if it has one.
    public var followSetting: (mode: FollowMode, speed: Double)? {
        steps.last { $0.act == .follow }.map { ($0.followMode, $0.followSpeed) }
    }

    /// When and what, in a few words: "⌃⌘T", "2 clicks on the Imp · only if Safari is in front".
    public var triggerSummary: String {
        let when = trigger.event == .keys ? (hotkey?.displayString ?? String(localized: "No keys yet")) : trigger.summary
        return ([when] + conditions.map(\.summary)).joined(separator: " · ")
    }
}

/// What you hand an Imp to work on: something you copied, pasted into its text box, or said.
public enum Clip: Equatable, Sendable {
    case text(String)
    case image(EncodedImage)
}
