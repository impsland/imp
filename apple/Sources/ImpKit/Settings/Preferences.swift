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

/// What is drawn on coloured controls (a filled button, the chosen segment, a switch that is on).
public enum ControlInk: String, Codable, CaseIterable, Sendable, Identifiable {
    case white, black
    public var id: String { rawValue }
}

/// Everything the user can configure. Stored as one JSON blob. API keys live apart from it: in a
/// private file (`KeyFile`), or in the Keychain if the user asks for that (`keysInKeychain`).
public struct ImpPreferences: Codable, Hashable, Sendable {
    public var ai = AIConfig()
    /// Triggers: when something happens, an Imp does something. Each is shared by every Imp
    /// (`performer` nil) or belongs to one Imp (see `SettingScope`). None until a kit or the person adds some.
    public var shortcuts: [Shortcut] = []
    /// The MCP server library. Each Imp picks the ones it uses (`ImpProfile.servers`).
    public var mcpServers: [MCPServerConfig] = []
    public var appearance: Appearance = .system
    /// White or black text, icons and switch knobs on coloured controls. White unless the person
    /// chooses black.
    public var controlInk: ControlInk {
        get { ink ?? .white }
        set { ink = newValue }
    }
    private var ink: ControlInk?
    /// Imp entertains itself in quiet moments (glances, humming, ideas).
    public var antics = true
    /// Mouse games: circle Imp, swish in front of its face, stroke its head.
    public var mouseGames = true
    /// Animations the user switched off or gave other triggers (the rest use their defaults).
    public var animations: AnimationRules = [:]
    /// The first run (waking an Imp with a Brain) was shown once. Optional, so older settings load.
    private var firstRunShown: Bool?
    public var firstRunSeen: Bool {
        get { firstRunShown ?? false }
        set { firstRunShown = newValue }
    }
    /// Storage for `animationLibrary` (optional, so older settings load).
    var customAnimations: [MadeAnimation]?
    /// 0 = never.
    public var bubbleAutoHideSeconds: Double = 30
    /// The bubble's background (Mac only). Optional storage, so settings without it load with the default.
    public var bubbleAppearance: BubbleAppearance {
        get { bubbleLook ?? BubbleAppearance() }
        set { bubbleLook = newValue }
    }
    private var bubbleLook: BubbleAppearance?
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
    /// The size of the home window the person chose in Settings (the last one chosen: resizing by hand does not change it).
    public var windowPreset: WindowPreset {
        get { window ?? WindowSizing.standard }
        set { window = newValue }
    }
    private var window: WindowPreset?
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
    /// Keeps API keys in the login Keychain instead of a private file. Off unless the user turns it
    /// on: macOS may ask for their password when Imp reads a key from there (after an update, say).
    public var keysInKeychain: Bool {
        get { keychain ?? false }
        set { keychain = newValue }
    }
    private var keychain: Bool?
    /// The Den the user chose, a host name or URL such as `den.example.com`. Imp's own Den until
    /// they change it. Empty: no Den (see `DenServer`). Independent of `hop`.
    public var den: String {
        get { denAddress ?? ServerKind.den.defaultAddress }
        set { denAddress = newValue }
    }
    private var denAddress: String?
    /// The Hop the user chose, as `host:port`. Imp's own Hop until they change it. Empty: no Hop
    /// (see `HopServer`). Independent of `den`.
    public var hop: String {
        get { hopAddress ?? ServerKind.hop.defaultAddress }
        set { hopAddress = newValue }
    }
    private var hopAddress: String?
    /// What the home window's canvas looks like behind the Imps (see `CanvasBackground`).
    public var background: CanvasBackground {
        get { canvasBackground ?? CanvasBackground() }
        set { canvasBackground = newValue }
    }
    private var canvasBackground: CanvasBackground?
    /// BCP-47 identifier for dictation. Empty = system language.
    public var dictationLocale = ""
    /// The troupe. Always at least one: the little red Imp, waiting in the app's window.
    public var imps: [ImpProfile] = [.waiting]

    /// Bare settings: one waiting Imp and nothing else. A fresh install starts from `firstLaunch`,
    /// which adds the starter kit. Decoding saved settings never goes through here.
    public init() {}

    /// Keeps the Brain the first run checked: its service (one already there for the same address is reused),
    /// its model, as the default Brain. `imp` follows the default Brain from now on.
    /// Returns the service. The key is not kept here.
    @discardableResult
    public mutating func adopt(_ brain: FirstRunBrain, for imp: UUID) -> UUID {
        let wanted = brain.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id: UUID
        if let known = ai.services.first(where: { $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }) {
            id = known.id
        } else {
            let made = Service(name: brain.name, baseURL: brain.baseURL, model: brain.model)
            ai.add(made)
            id = made.id
        }
        ai.setModel(brain.model, for: id)
        ai.brain.service = id
        if let i = imps.firstIndex(where: { $0.id == imp }) { imps[i].brain = nil }
        return id
    }

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
