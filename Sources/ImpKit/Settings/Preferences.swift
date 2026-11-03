import Foundation

/// Where Imps talk when one messages another (`imp_message`).
public enum ImpTalk: String, Codable, CaseIterable, Sendable, Identifiable {
    /// In a chat of their own: the receiver keeps one per Imp it talks with.
    case own
    /// In the receiver's chat with you.
    case shared
    /// The Imp that sends the message says which, message by message.
    case decides

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .own: String(localized: "A chat of their own")
        case .shared: String(localized: "Your chat")
        case .decides: String(localized: "The Imp decides")
        }
    }

    /// Where one message goes: `asked` is the sender's pick (`own` or `shared`), only heard when it decides.
    public func place(asked: String?) -> Place {
        switch self {
        case .own: .own
        case .shared: .shared
        case .decides: asked?.lowercased() == Place.shared.rawValue ? .shared : .own
        }
    }

    public enum Place: String, Sendable {
        case own, shared
    }
}

public enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
}

/// Everything the user can configure. Stored as one JSON blob. API keys live apart from it: in a
/// private file (`KeyFile`), or in the Keychain if the user asks for that (`keysInKeychain`).
public struct ImpPreferences: Codable, Hashable, Sendable {
    public var ai = AIConfig()
    /// Shortcuts: keys that hand the clipboard to an Imp with an instruction. Each belongs to an
    /// Imp (`performer`) and works while that Imp is activated. There are none until you make some.
    public var shortcuts: [Shortcut] = []
    /// The MCP server library. Each Imp picks the ones it uses (`ImpProfile.servers`).
    public var mcpServers: [MCPServerConfig] = []
    public var appearance: Appearance = .system
    /// Imp entertains itself in quiet moments (glances, humming, ideas).
    public var antics = true
    /// Mouse games: circle Imp, swish in front of its face, stroke its head.
    public var mouseGames = true
    /// Animations the user switched off or gave other triggers (the rest use their defaults).
    public var animations: [Reaction: AnimationRule] = [:]
    /// Storage for `animationLibrary` (optional, so older settings load).
    var customAnimations: [MadeAnimation]?
    /// The default body triggers (sleep, wake) already added, by id (see `addBodyDefaults()`).
    /// Optional, so older settings load.
    var addedDefaults: [UUID]?
    /// 0 = never.
    public var bubbleAutoHideSeconds: Double = 30
    /// How long a model request may take and how it is retried (see `RequestLimits`). Optional storage, so older settings load.
    public var requests: RequestLimits {
        get { requestLimits ?? .standard }
        set { requestLimits = newValue.clamped }
    }
    private var requestLimits: RequestLimits?
    /// Audio and video in a reply may start on their own when the Imp asks (`#autoplay`).
    public var autoplaysMedia: Bool {
        get { mediaAutoplay ?? true }
        set { mediaAutoplay = newValue }
    }
    /// Optional, so settings saved before it existed still load (a missing key is nil).
    private var mediaAutoplay: Bool?
    /// How an answer's audio shows in the speech bubble (the chat always has players).
    public var voiceStyle: VoiceStyle {
        get { voice ?? .both }
        set { voice = newValue }
    }
    private var voice: VoiceStyle?
    /// The most lines the bubble's text box grows to before it scrolls (2 to 12). Optional storage, so older settings load.
    public var inputMaxLines: Int {
        get { BubbleSizing.clampedLines(inputLines ?? BubbleSizing.defaultInputLines) }
        set { inputLines = BubbleSizing.clampedLines(newValue) }
    }
    private var inputLines: Int?
    /// The size the user gave the full bubble (the chat), kept between launches. `nil`: the default size.
    public var chatBubbleSize: CGSize? {
        get {
            guard let w = chatWidth, let h = chatHeight, w > 0, h > 0 else { return nil }
            return CGSize(width: w, height: h)
        }
        set { chatWidth = newValue.map { Double($0.width) }; chatHeight = newValue.map { Double($0.height) } }
    }
    private var chatWidth: Double?
    private var chatHeight: Double?
    /// Where Imps talk to each other. Optional storage, so older settings load.
    public var impTalk: ImpTalk {
        get { talk ?? .own }
        set { talk = newValue }
    }
    private var talk: ImpTalk?
    /// Whether a message between Imps goes on in their latest conversation or starts a new one
    /// (see `TalkThreading`). Optional storage, so older settings load.
    public var talkThreading: TalkThreading {
        get { threading ?? .decides }
        set { threading = newValue }
    }
    private var threading: TalkThreading?
    /// Minutes after which a conversation between two Imps counts as over (the `recent` rule, and what the
    /// sender's own choice falls back to).
    public var talkWindowMinutes: Int {
        get { min(max(windowMinutes ?? 60, 1), TalkThreading.maxWindowMinutes) }
        set { windowMinutes = min(max(newValue, 1), TalkThreading.maxWindowMinutes) }
    }
    private var windowMinutes: Int?
    /// A chat that would send the model this many tokens (estimated, about four characters each)
    /// gets a gentle suggestion to recap it or start a new chat. One of `contextNoticeChoices`.
    public var contextNoticeTokens: Int {
        get { noticeTokens.flatMap { Self.contextNoticeChoices.contains($0) ? $0 : nil } ?? Self.contextNoticeDefault }
        set { noticeTokens = Self.contextNoticeChoices.contains(newValue) ? newValue : nil }
    }
    public static let contextNoticeChoices = [50_000, 100_000, 250_000, 500_000, 750_000, 1_000_000]
    public static let contextNoticeDefault = 250_000
    private var noticeTokens: Int?
    /// Keeps API keys in the login Keychain instead of a private file. Off unless the user turns it
    /// on: macOS may ask for their password when Imp reads a key from there (after an update, say).
    public var keysInKeychain: Bool {
        get { keychain ?? false }
        set { keychain = newValue }
    }
    private var keychain: Bool?
    /// The Imp server (its Den and Hop) the user picked: a host name such as `imp.example.org`, or
    /// `http://localhost:8080` while trying one out. Empty: none (see `ImpServer`).
    public var server: String {
        get { serverAddress ?? "" }
        set { serverAddress = newValue }
    }
    private var serverAddress: String?
    /// BCP-47 identifier for dictation. Empty = system language.
    public var dictationLocale = ""
    /// The troupe. Always at least one: the little red Imp, waiting in the app's window.
    public var imps: [ImpProfile] = [.waiting]

    /// A fresh install: one click types, a double-click opens settings, and the default body triggers
    /// (sleep, wake) are there. Decoding saved settings never goes through here.
    public init() {
        var one = Shortcut(name: String(localized: "Type"), prompt: "", usesClipboard: false, trigger: .clicks(1), command: .type)
        one.id = Self.clickID
        var two = Shortcut(name: "Settings", prompt: "", usesClipboard: false, trigger: .clicks(2), command: .settings)
        two.id = Self.doubleClickID
        shortcuts = [one, two]
        addBodyDefaults()
    }

    /// Stable identities for the click triggers every install starts with.
    public static let clickID = UUID(uuidString: "C11C0000-0000-4000-8000-000000000001")!
    public static let doubleClickID = UUID(uuidString: "C11C0000-0000-4000-8000-000000000002")!

    /// Removes a service everywhere: the default brain and every Imp's own brain. An Imp that used it
    /// follows the default brain from now on, with the default service's model, not the one it had
    /// picked for the service that's gone. With no service left it sleeps until it gets one.
    public mutating func removeService(_ id: UUID) {
        let wasDefault = ai.brain.service == id
        ai.remove(service: id)
        for i in imps.indices { imps[i].brain = imps[i].brain?.without(service: id, wasDefault: wasDefault) }
    }

    /// Removes an MCP server from the library and from every Imp that used it.
    public mutating func removeServer(_ id: UUID) {
        mcpServers.removeAll { $0.id == id }
        for i in imps.indices { imps[i].servers.removeAll { $0 == id } }
    }

    /// The Imp that performs an action: its own performer if it's activated, else `fallback`.
    public func performer(of action: Shortcut, fallback: UUID) -> UUID {
        action.performer.flatMap { id in imps.contains { $0.id == id && $0.isActive } ? id : nil } ?? fallback
    }

    /// An Imp's shortcuts, in priority order.
    public func shortcuts(of imp: UUID) -> [Shortcut] { shortcuts.filter { $0.performer == imp } }

    /// Shortcuts every Imp answers to (no performer of their own).
    public var sharedShortcuts: [Shortcut] { shortcuts.filter { $0.performer == nil } }

    /// Shortcuts that should listen right now: switched on, and their Imp is out on the desktop.
    public var liveShortcuts: [Shortcut] {
        let active = Set(imps.filter(\.isActive).map(\.id))
        return shortcuts.filter { a in a.isEnabled && (a.performer.map(active.contains) ?? !active.isEmpty) }
    }

    /// What `count` clicks on `imp` set off: its own trigger first, else one every Imp shares.
    /// `state` decides the conditions (nil: ignore triggers that have any).
    public func clickShortcut(_ count: Int, on imp: UUID, in state: MacState?) -> Shortcut? {
        let candidates = shortcuts.filter { s in
            s.isEnabled && s.trigger.kind == .clicks && s.trigger.clicks == count && (s.performer == imp || s.performer == nil)
                && (state.map { st in s.conditions.allSatisfy { $0.holds(in: st) } } ?? s.conditions.isEmpty)
        }
        return candidates.first { $0.performer == imp } ?? candidates.first
    }

    /// The most clicks in a row anything on `imp` answers to (a click waits for more only if needed).
    public func mostClicks(on imp: UUID) -> Int {
        shortcuts.filter { $0.isEnabled && $0.trigger.kind == .clicks && ($0.performer == imp || $0.performer == nil) }
            .map(\.trigger.clicks).max() ?? 0
    }

    /// Servers some activated Imp uses (the only ones worth running).
    public var liveServers: [MCPServerConfig] {
        let used = Set(imps.filter(\.isActive).flatMap(\.servers))
        return mcpServers.filter { used.contains($0.id) }.map { var s = $0; s.isEnabled = true; return s }
    }
}

extension ImpProfile {
    /// The first Imp of a fresh install: deactivated, so it waits in the app's window to be let out.
    public static var waiting: ImpProfile {
        var p = ImpProfile.imp
        p.isActive = false
        return p
    }
}
