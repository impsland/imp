import Foundation

/// What a plain click on Imp does (⌥-click does the other one).
public enum ClickAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case type, talk
    public var id: String { rawValue }
}

public enum Appearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
}

/// Everything the user can configure. Stored as one JSON blob. API keys live in the Keychain.
public struct ImpPreferences: Codable, Hashable, Sendable {
    public var ai = AIConfig()
    /// Shortcuts: keys that hand the clipboard to an Imp with an instruction. Each belongs to an
    /// Imp (`performer`) and works while that Imp is activated. There are none until you make some.
    public var shortcuts: [Shortcut] = []
    /// The MCP server library. Each Imp picks the ones it uses (`ImpProfile.servers`).
    public var mcpServers: [MCPServerConfig] = []
    public var click: ClickAction = .type
    public var appearance: Appearance = .system
    /// Imp entertains itself in quiet moments (glances, humming, ideas).
    public var antics = true
    /// Mouse games: circle Imp, swish in front of its face, stroke its head.
    public var mouseGames = true
    /// Animations the user switched off or gave other triggers (the rest use their defaults).
    public var animations: [Reaction: AnimationRule] = [:]
    /// Double-clicking an Imp opens its settings.
    public var doubleClickOpensSettings = true
    /// 0 = never.
    public var bubbleAutoHideSeconds: Double = 30
    /// Audio and video in a reply may start on their own when the Imp asks (`#autoplay`).
    public var autoplaysMedia: Bool {
        get { mediaAutoplay ?? true }
        set { mediaAutoplay = newValue }
    }
    /// Optional, so settings saved before it existed still load (a missing key is nil).
    private var mediaAutoplay: Bool?
    /// BCP-47 identifier for dictation. Empty = system language.
    public var dictationLocale = ""
    /// The troupe. Always at least one: the little red Imp, waiting in the app's window.
    public var imps: [ImpProfile] = [.waiting]

    public init() {}

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

    /// Shortcuts that should listen right now: switched on, and their Imp is out on the desktop.
    public var liveShortcuts: [Shortcut] {
        let active = Set(imps.filter(\.isActive).map(\.id))
        return shortcuts.filter { a in a.isEnabled && (a.performer.map(active.contains) ?? !active.isEmpty) }
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
