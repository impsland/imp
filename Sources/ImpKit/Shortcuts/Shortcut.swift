import Foundation

/// A trigger and what it sets off: **when this happens → this Imp does what `prompt` says**, with
/// whatever you copied (text or a picture) unless it's set to send the instruction alone. What
/// happens can be keys you press, clicks on the Imp, or something on your Mac (`Trigger`). The
/// Imp's model decides how to respond: it answers, and uses its tools when the job needs them.
/// A few triggers just open something instead (`Command`), like a click opening the text box.
///
/// (Called a shortcut for history's sake: keys were the first trigger.)
public struct Shortcut: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var isEnabled = true
    /// The keys, when the trigger is `.keys`.
    public var hotkey: Hotkey?
    /// What to do, in plain words. Empty (with the clipboard): the Imp just responds to what you copied.
    public var prompt: String
    /// Which Imp does this. `nil` = every Imp: the one you click, or else whichever you talked to last.
    public var performer: UUID?

    /// What happens to the Imp when it goes off.
    public enum Command: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Hands the instruction (and what happened) to the Imp's model.
        case ask
        /// Opens a text box above the Imp (or closes the one that's open).
        case type
        /// Starts listening.
        case talk
        /// Opens the chat.
        case chat
        /// Opens the Imp's settings.
        case settings
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .ask: String(localized: "Ask the Imp")
            case .type: String(localized: "Open a text box")
            case .talk: String(localized: "Start listening")
            case .chat: String(localized: "Open the chat")
            case .settings: String(localized: "Open its settings")
            }
        }

        public var symbol: String {
            switch self {
            case .ask: "sparkles"
            case .type: "keyboard"
            case .talk: "mic"
            case .chat: "bubble.left.and.bubble.right"
            case .settings: "slider.horizontal.3"
            }
        }
    }

    /// What sets it off. Optional storage, so shortcuts saved before triggers existed are keys.
    public var trigger: Trigger {
        get { when ?? .keys }
        set { when = newValue }
    }
    private var when: Trigger?

    /// What must also be true when it goes off ("only if the battery is low").
    public var conditions: [Trigger] {
        get { onlyIf ?? [] }
        set { onlyIf = newValue.isEmpty ? nil : newValue }
    }
    private var onlyIf: [Trigger]?

    public var command: Command {
        get { does ?? .ask }
        set { does = newValue == .ask ? nil : newValue }
    }
    private var does: Command?

    /// The keys to listen for: set, and the trigger is keys.
    public var keys: Hotkey? { trigger.kind == .keys ? hotkey : nil }

    /// Sends what's on the clipboard along with the instruction. Off: the instruction alone.
    public var usesClipboard: Bool {
        get { clipboard ?? true }
        set { clipboard = newValue }
    }
    /// Optional, so shortcuts saved before it existed still load (they used the clipboard).
    private var clipboard: Bool?

    /// Can run: it has something to send (what you copied, or an instruction).
    public var isRunnable: Bool {
        command != .ask || usesClipboard || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(name: String, isEnabled: Bool = true, hotkey: Hotkey? = nil, prompt: String, performer: UUID? = nil,
                usesClipboard: Bool = true, trigger: Trigger? = nil, conditions: [Trigger] = [], command: Command = .ask) {
        self.name = name
        self.isEnabled = isEnabled
        self.hotkey = hotkey
        self.prompt = prompt
        self.performer = performer
        self.clipboard = usesClipboard
        self.when = trigger
        self.onlyIf = conditions.isEmpty ? nil : conditions
        self.does = command == .ask ? nil : command
    }

    /// When and what, in a few words: "⌃⌘T", "2 clicks on the Imp · only if Safari is in front".
    public var triggerSummary: String {
        let when = trigger.kind == .keys ? (hotkey?.displayString ?? String(localized: "No keys yet")) : trigger.summary
        let ifs = conditions.map(\.conditionSummary)
        return ([when] + ifs).joined(separator: " · ")
    }
}

/// What you hand an Imp to work on: something you copied, pasted into its text box, or said.
public enum Clip: Equatable, Sendable {
    case text(String)
    case image(EncodedImage)
}
