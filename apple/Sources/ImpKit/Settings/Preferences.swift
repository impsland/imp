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

/// Everything the user can configure. Its shared part (services, tool servers, triggers, animations, requests,
/// talk, link and each Imp's identity, model and tools) lives in the shared configuration
/// (`SharedConfigStore`, `docs/architecture/configuration.md`) and its screen part in `LocalPreferences`.
/// API keys are in `auth.json` next to `imp.json`, never here.
public struct ImpPreferences: Codable, Hashable, Sendable {
    public var ai = AIConfig()
    /// Triggers: when something happens, an Imp does something. Each is shared by every Imp
    /// (`performer` nil) or belongs to one Imp (see `SettingScope`). None until the person (or the Imp, on
    /// request) adds some: nothing the Imp does in answer to a click, a key or the Mac is built in.
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
    /// The first run (waking an Imp with a Brain) was shown once. Stored only once set: unset reads as the default.
    private var firstRunShown: Bool?
    public var firstRunSeen: Bool {
        get { firstRunShown ?? false }
        set { firstRunShown = newValue }
    }
    /// Storage for `animationLibrary` (stored only once set: unset reads as the default).
    var customAnimations: [MadeAnimation]?
    /// 0 = never.
    public var bubbleAutoHideSeconds: Double = 30
    /// The bubble's background (Mac only). Optional storage, so settings without it load with the default.
    public var bubbleAppearance: BubbleAppearance {
        get { bubbleLook ?? BubbleAppearance() }
        set { bubbleLook = newValue }
    }
    private var bubbleLook: BubbleAppearance?
    /// How long a model request may take and how it is retried (see `RequestLimits`). Stored only
    /// once set: unset reads as the default.
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
    /// The most lines the bubble's text box grows to before it scrolls (2 to 12). Stored only once
    /// set: unset reads as the default.
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
    /// Where Imps talk to each other. Stored only once set: unset reads as the default.
    public var impTalk: ImpTalk {
        get { talk ?? .own }
        set { talk = newValue }
    }
    private var talk: ImpTalk?
    /// Whether a message between Imps goes on in their latest conversation or starts a new one
    /// (see `TalkThreading`). Stored only once set: unset reads as the default.
    public var talkThreading: TalkThreading {
        get { threading ?? .decides }
        set { threading = newValue }
    }
    private var threading: TalkThreading?
    /// Whether an Imp waits for the answer of an Imp it messages (see `TalkWaiting`). Stored only
    /// once set: unset reads as the default.
    public var talkWaiting: TalkWaiting {
        get { waiting ?? .decides }
        set { waiting = newValue }
    }
    private var waiting: TalkWaiting?
    /// Minutes after which a conversation between two Imps counts as over (the `recent` rule, and what the
    /// sender's own choice falls back to).
    public var talkWindowMinutes: Int {
        get { min(max(windowMinutes ?? 60, 1), TalkThreading.maxWindowMinutes) }
        set { windowMinutes = min(max(newValue, 1), TalkThreading.maxWindowMinutes) }
    }
    private var windowMinutes: Int?
    /// The Hop the user chose, as `host:port`. Imp's own Hop until they change it. Empty: no Hop
    /// (see `HopServer`).
    public var hop: String {
        get { hopAddress ?? ServerKind.hop.defaultAddress }
        set { hopAddress = newValue }
    }
    private var hopAddress: String?
    /// The HTML document behind the Imps in the home window (see `RoomBackground`). The Imps set it.
    /// Setting the default (or nil) stores nothing.
    public var background: String {
        get { backgroundHTML ?? RoomBackground.defaultHTML }
        set { backgroundHTML = newValue == RoomBackground.defaultHTML ? nil : newValue }
    }
    private var backgroundHTML: String?
    /// BCP-47 identifier for dictation. Empty = system language. `ListeningLanguages.automatic` listens in
    /// several at once and keeps the one that fits (`dictationLanguages`).
    public var dictationLocale = ""
    /// The languages Automatic listens in, at most `ListeningLanguages.maxLanguages`. Empty: the device's own.
    public var dictationLanguages: [String] {
        get { dictationLanguageList ?? [] }
        set { dictationLanguageList = newValue.isEmpty ? nil : Array(newValue.prefix(ListeningLanguages.maxLanguages)) }
    }
    /// Optional, so settings saved before it still load.
    private var dictationLanguageList: [String]?
    /// The tool groups switched off for each linked device (see `DeviceToolLimits`). Stored only once set.
    public var deviceToolLimits: DeviceToolLimits {
        get { toolLimits ?? DeviceToolLimits() }
        set { toolLimits = newValue }
    }
    private var toolLimits: DeviceToolLimits?
    /// The troupe. It may be empty: an Imp is hatched with its first Brain (see `FirstRunTarget`).
    public var imps: [ImpProfile] = []

    /// Bare settings: no Imps and nothing else, with no triggers and no animations. A fresh
    /// install starts from here. Decoding saved settings never goes through here.
    public init() {}

    /// Keeps the Brain the first run checked: its service (one already there for the same address is reused),
    /// its model, as the default Brain. `imp` follows the default Brain.
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
    /// follows the default brain, with the default service's model, not the one it had
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


/// One Imp's part that belongs to this Mac's screen, not to the configuration `imp` shares.
public struct LocalImp: Codable, Hashable, Sendable {
    public var isActive = true
    public var knowsFavorite = false
    public var origin: CGPoint?
    public var awayOn: UUID?
    public init() {}
}

/// What stays with the app (`docs/architecture/configuration.md`, "Where it lives"): appearance, the bubble,
/// the window, media and voice, listening languages, the first run, and for each Imp whether it is out, where
/// it stands, whether the person found its favourite colour and which phone it is on. Kept in `UserDefaults`.
/// The dictation languages are this Mac's (the languages its speech recognition has), so `imp` does not share them.
public struct LocalPreferences: Codable, Hashable, Sendable {
    public var appearance: Appearance = .system
    var ink: ControlInk?
    public var antics = true
    public var mouseGames = true
    var firstRunShown: Bool?
    public var bubbleAutoHideSeconds: Double = 30
    var bubbleLook: BubbleAppearance?
    var mediaAutoplay: Bool?
    var voice: VoiceStyle?
    var inputLines: Int?
    var chatWidth: Double?
    var chatHeight: Double?
    var window: WindowPreset?
    var backgroundHTML: String?
    public var dictationLocale = ""
    var dictationLanguageList: [String]?
    /// By the Imp's id.
    public var imps: [UUID: LocalImp] = [:]
    /// The troupe's order: the files only know names.
    public var order: [UUID] = []

    public init() {}
}

extension ImpPreferences {
    /// The part that stays with the app.
    public var local: LocalPreferences {
        var l = LocalPreferences()
        l.appearance = appearance; l.ink = ink; l.antics = antics; l.mouseGames = mouseGames
        l.firstRunShown = firstRunShown; l.bubbleAutoHideSeconds = bubbleAutoHideSeconds; l.bubbleLook = bubbleLook
        l.mediaAutoplay = mediaAutoplay; l.voice = voice; l.inputLines = inputLines; l.chatWidth = chatWidth
        l.chatHeight = chatHeight; l.window = window; l.backgroundHTML = backgroundHTML
        l.dictationLocale = dictationLocale; l.dictationLanguageList = dictationLanguageList
        for imp in imps {
            var i = LocalImp()
            i.isActive = imp.isActive; i.knowsFavorite = imp.knowsFavorite; i.origin = imp.origin; i.awayOn = imp.awayOn
            l.imps[imp.id] = i
        }
        l.order = imps.map(\.id)
        return l
    }

    /// Puts the app's own part over these preferences (read from the shared configuration): the screen settings, each
    /// Imp's state, and the troupe in the order it was in (Imps the app has not seen follow, in the files' order).
    public mutating func apply(_ l: LocalPreferences) {
        appearance = l.appearance; ink = l.ink; antics = l.antics; mouseGames = l.mouseGames
        firstRunShown = l.firstRunShown; bubbleAutoHideSeconds = l.bubbleAutoHideSeconds; bubbleLook = l.bubbleLook
        mediaAutoplay = l.mediaAutoplay; voice = l.voice; inputLines = l.inputLines; chatWidth = l.chatWidth
        chatHeight = l.chatHeight; window = l.window; backgroundHTML = l.backgroundHTML
        dictationLocale = l.dictationLocale; dictationLanguageList = l.dictationLanguageList
        for i in imps.indices {
            guard let state = l.imps[imps[i].id] else { continue }
            imps[i].isActive = state.isActive; imps[i].knowsFavorite = state.knowsFavorite
            imps[i].origin = state.origin; imps[i].awayOn = state.awayOn
        }
        let rank = Dictionary(l.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        imps = imps.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }
}
