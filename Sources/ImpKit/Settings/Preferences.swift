import Foundation

/// What a plain click on Imp did before clicks became triggers (only read to carry it over).
public enum ClickAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case type, talk
    public var id: String { rawValue }
}

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
        case .own: "In a chat of their own"
        case .shared: "In the chat with you"
        case .decides: "The Imp decides"
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
    /// Before triggers: what a click did, and whether a double-click opened settings. Only read once,
    /// to set up the click triggers that replace them (`upgrade()`).
    public var click: ClickAction = .type
    public var appearance: Appearance = .system
    /// Imp entertains itself in quiet moments (glances, humming, ideas).
    public var antics = true
    /// Mouse games: circle Imp, swish in front of its face, stroke its head.
    public var mouseGames = true
    /// Animations the user switched off or gave other triggers (the rest use their defaults).
    public var animations: [Reaction: AnimationRule] = [:]
    public var doubleClickOpensSettings = true
    /// The click triggers were set up (see `upgrade()`). Optional, so older settings load.
    private var clicksSetUp: Bool?
    /// 0 = never.
    public var bubbleAutoHideSeconds: Double = 30
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
    /// Where Imps talk to each other. Optional storage, so older settings load.
    public var impTalk: ImpTalk {
        get { talk ?? .own }
        set { talk = newValue }
    }
    private var talk: ImpTalk?
    /// Keeps API keys in the login Keychain instead of a private file. Off unless the user turns it
    /// on: macOS may ask for their password when Imp reads a key from there (after an update, say).
    public var keysInKeychain: Bool {
        get { keychain ?? false }
        set { keychain = newValue }
    }
    private var keychain: Bool?
    /// BCP-47 identifier for dictation. Empty = system language.
    public var dictationLocale = ""
    /// The troupe. Always at least one: the little red Imp, waiting in the app's window.
    public var imps: [ImpProfile] = [.waiting]

    public init() { upgrade() }

    /// Brings settings saved by an older version up to date. Clicks used to be fixed (a click typed
    /// or talked, a double-click opened settings): now they're triggers shared by every Imp, which
    /// start out doing just that and can be changed like any other.
    public mutating func upgrade() {
        giveServicesModels()
        guard clicksSetUp != true else { return }
        clicksSetUp = true
        // "Mouse games" was a switch for every cursor game at once: now each animation has its own.
        if !mouseGames {
            for r in Reaction.allCases where rule(for: r).triggers.contains(where: \.watchesCursor) { setEnabled(false, for: r) }
            mouseGames = true
        }
        guard !shortcuts.contains(where: { $0.trigger.kind == .clicks }) else { return }
        var one = Shortcut(name: click == .talk ? "Talk" : "Type", prompt: "", usesClipboard: false,
                           trigger: .clicks(1), command: click == .talk ? .talk : .type)
        one.id = Self.clickID
        shortcuts.insert(one, at: 0)
        if doubleClickOpensSettings {
            var two = Shortcut(name: "Settings", prompt: "", usesClipboard: false, trigger: .clicks(2), command: .settings)
            two.id = Self.doubleClickID
            shortcuts.insert(two, at: 1)
        }
    }

    /// Models used to belong to brains: every Imp that picked a service had to name a model too.
    /// Now each service has one. A service without one takes the model the default brain or an Imp
    /// named for it, and the Imps that named that same model just follow the service from now on.
    /// The default brain's model stays as the last fallback, for Imps on a service that got none.
    /// (Changes nothing once every service has a model, so it's safe on every launch.)
    private mutating func giveServicesModels() {
        for i in ai.services.indices where ai.services[i].model.isEmpty {
            let id = ai.services[i].id
            let legacy = ai.service()?.id == id ? ai.brain.model : ""
            let named = [legacy] + imps.compactMap { $0.brain }.filter { ai.service(in: $0)?.id == id }.map(\.model)
            guard let model = named.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { continue }
            ai.services[i].model = model
            for j in imps.indices where imps[j].brain.map({ ai.service(in: $0)?.id == id && $0.model.trimmingCharacters(in: .whitespaces) == model }) == true {
                imps[j].brain?.model = ""
            }
        }
    }

    /// Stable identities for the click triggers every install starts with.
    public static let clickID = UUID(uuidString: "C11C0000-0000-4000-8000-000000000001")!
    public static let doubleClickID = UUID(uuidString: "C11C0000-0000-4000-8000-000000000002")!

    /// Removes a service everywhere: the default brain and every Imp's own brain.
    public mutating func removeService(_ id: UUID) {
        ai.remove(service: id)
        for i in imps.indices { imps[i].brain?.reassign(from: id, to: ai.services.first?.id) }
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
