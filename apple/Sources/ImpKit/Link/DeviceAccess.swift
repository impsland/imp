import Foundation

/// What a linked device may do with this Mac's Imps, as plugs and sockets: each capability is a plug, and when it is
/// plugged into the device's socket the Imps here have that capability for that device. The canvas shows which plugs
/// are in on each line and the sheets plug and unplug them, so both read it from here.
///
/// "Talk & files" is the device being trusted (Mine): it also gates serving files, messages between devices and tools
/// at all, so it stays a plug of its own and is never worked out from the tools. A tool's plug is its limit
/// (`DeviceToolLimits`), which only counts while the device is trusted.
public struct DeviceAccess: Equatable, Sendable {
    public struct Capability: Equatable, Sendable, Identifiable {
        public var id: String
        public var symbol: String
        public var title: String
        public var allowed: Bool
        public init(id: String, symbol: String, title: String, allowed: Bool) {
            self.id = id; self.symbol = symbol; self.title = title; self.allowed = allowed
        }
    }

    /// The id of the first plug, "Talk & files".
    public static let talk = "talk"
    public static let talkSymbol = "person.fill.checkmark"

    public var trusted: Bool
    /// "Talk & files" first, then the tools the Imps here offer.
    public var capabilities: [Capability]

    public init(trusted: Bool, capabilities: [Capability]) {
        self.trusted = trusted
        self.capabilities = capabilities
    }

    /// The plugs of `peer`: the trust, then every tool group an Imp here uses, the commands tool when one does and each
    /// enabled tool server, each allowed unless limited for this device.
    public static func of(peer: UUID, trusted: Bool, prefs: ImpPreferences) -> DeviceAccess {
        func tool(_ id: String, _ symbol: String, _ title: String) -> Capability {
            Capability(id: id, symbol: symbol, title: title, allowed: prefs.deviceToolLimits.isAllowed(group: id, on: peer))
        }
        var list = [Capability(id: talk, symbol: talkSymbol, title: String(localized: "devices.access.talk"), allowed: trusted)]
        list += ImpToolGroup.allCases.filter { group in prefs.imps.contains { $0.uses(group) } }
            .map { tool(DeviceToolLimits.groupID($0), $0.symbol, $0.title) }
        if prefs.imps.contains(where: \.usesShell) {
            list.append(tool(DeviceToolLimits.commands, "terminal.fill", String(localized: "devices.tools.commands")))
        }
        list += prefs.mcpServers.filter(\.isEnabled).map { tool(DeviceToolLimits.groupID(server: $0.id), "puzzlepiece.extension.fill", $0.name) }
        return DeviceAccess(trusted: trusted, capabilities: list)
    }

    /// The tools that can be plugged (everything but the trust).
    public var tools: [Capability] { capabilities.filter { $0.id != Self.talk } }

    /// The plugs that are in right now: nothing is while the device isn't trusted, else "Talk & files" and the allowed tools.
    public var pluggedIn: [Capability] { trusted ? capabilities.filter { $0.id == Self.talk || $0.allowed } : [] }

    /// Whether the plug `id` is in, as the device is trusted and the tool allowed.
    public func isPlugged(_ id: String) -> Bool { pluggedIn.contains { $0.id == id } }

    /// The access with plug `id` plugged in or out. Plugging a tool while the device is not trusted trusts it too, as
    /// a tool does nothing otherwise. Unplugging "Talk & files" leaves the tool limits as they are, so they apply
    /// again when it is plugged back.
    public func plugging(_ id: String, _ on: Bool) -> DeviceAccess {
        var next = self
        if id == Self.talk {
            next.trusted = on
        } else if next.capabilities.contains(where: { $0.id == id }) {
            next.capabilities = capabilities.map { var c = $0; if c.id == id { c.allowed = on }; return c }
            if on { next.trusted = true }
        }
        if let index = next.capabilities.firstIndex(where: { $0.id == Self.talk }) { next.capabilities[index].allowed = next.trusted }
        return next
    }

    /// `limits` with this access's tool plugs written for `peer`.
    public func limits(applying limits: DeviceToolLimits, peer: UUID) -> DeviceToolLimits {
        var next = limits
        for tool in tools { next.set(tool.allowed, group: tool.id, on: peer) }
        return next
    }
}
