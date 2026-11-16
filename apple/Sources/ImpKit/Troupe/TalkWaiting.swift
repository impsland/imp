import Foundation
import ImpCore

/// Whether an Imp that messages another waits for the answer before it goes on. The rule is the core's
/// (`troupe::wants_wait`); the raw values are the ones the core and the settings file use.
public enum TalkWaiting: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Always wait, as before.
    case wait
    /// Never: the answer arrives later as a turn of its own.
    case dontWait = "dont_wait"
    /// The Imp chooses per message (`wait` in the tool).
    case decides

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wait: String(localized: "settings.talking.waiting.wait")
        case .dontWait: String(localized: "settings.talking.waiting.dont_wait")
        case .decides: String(localized: "settings.talking.waiting.decides")
        }
    }

    /// Whether this message waits. `asked`: the sender's own `wait` argument.
    public func waits(asked: Bool?) -> Bool { ImpCore.troupeWantsWait(waiting: rawValue, asked: asked) }
}

/// What an Imp can do, as the other Imps are told (`LinkImp.abilities`), sanitized by the core.
public enum ImpAbilities {
    /// `shell`, `browser` and its tool servers' names, in that order.
    public static func tags(shell: Bool, browser: Bool, servers: [String]) -> [String] {
        ImpCore.troupeAbilityTags(tags: (shell ? ["shell"] : []) + (browser ? ["browser"] : []) + servers)
    }

    /// For a profile: the shell when it may run commands, the browser when its page tool is on, and the
    /// names of the servers (`serverNames`: those of `profile.servers` that are in the library).
    public static func tags(of profile: ImpProfile, serverNames: [String]) -> [String] {
        let browser = profile.uses(.senses) && profile.uses(tool: ToolRegistry.ownID(.senses, tool: OwnTools.page))
        return tags(shell: profile.usesShell, browser: browser, servers: serverNames)
    }

    /// The core's view of a target for the message tool, from what a device said about it (sanitized again here).
    public static func profile(name: String, about: String?, abilities: [String]) -> ImpCore.TroupeTargetProfile {
        ImpCore.TroupeTargetProfile(name: name, about: about.flatMap { ImpCore.troupeAboutLine(text: $0) },
                                    abilities: ImpCore.troupeAbilityTags(tags: abilities))
    }
}
