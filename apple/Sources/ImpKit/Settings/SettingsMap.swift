import Foundation

/// The sections the All Imps settings are split into, in the order they are listed. Every platform
/// lists them as a rail or bar that is always one tap away. A map node or an attention item opens one.
public enum SettingsGroup: String, CaseIterable, Sendable, Identifiable {
    case app, bubble, talking, brains, devices, sharing, animations, privacy, backup

    public var id: String { rawValue }
}

/// One element of the settings map: this device, a connected service, a server or another device.
public struct SettingsNode: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case thisDevice, brains, tools, den, hop, desktop, phone }
    /// Ready, needs setup and off are the three for what the person sets up. Offline is a linked
    /// device that is set up but cannot be reached now.
    public enum State: Sendable { case ready, needsSetup, off, offline }

    public var id: String
    public var kind: Kind
    public var name: String
    public var state: State
    /// The Imps whose body is on this node.
    public var imps: [String] = []
    /// For this device: the Imps that have no Brain.
    public var sleeping: [String] = []
    /// For the Hop: it runs on this computer.
    public var isLocal = false
    /// For another device: this device can see it, and its tools can be used from here.
    public var seen = false
    public var toolsHere = false
    /// For another device: the server its link goes through.
    public var via: String?

    public init(id: String, kind: Kind, name: String, state: State, imps: [String] = [], sleeping: [String] = [],
                isLocal: Bool = false, seen: Bool = false, toolsHere: Bool = false, via: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.state = state; self.imps = imps
        self.sleeping = sleeping; self.isLocal = isLocal; self.seen = seen; self.toolsHere = toolsHere; self.via = via
    }

    /// The group of settings this node opens.
    public var group: SettingsGroup {
        switch kind {
        case .brains, .thisDevice, .tools: .brains
        case .den: .sharing
        case .hop, .desktop, .phone: .devices
        }
    }
}

/// Something to fix, with the group that fixes it.
public struct AttentionItem: Equatable, Identifiable, Sendable {
    public enum Reason: Equatable, Sendable {
        case noBrains, noBrain(String), denNotSet, hopNotSet, deviceOffline(String)
    }
    public var reason: Reason
    public var group: SettingsGroup
    public var id: String { "\(reason)" }
}

/// The Devices map and what needs attention, worked out from the preferences and the link state.
public enum SettingsMap {
    /// The map's nodes from the preferences and the core's device map.
    public static func nodes(prefs: ImpPreferences, map: DeviceMap) -> [SettingsNode] {
        let sleeping = prefs.imps.filter { prefs.ai.service(in: $0.brain) == nil }.map(\.name)
        func imps(on id: String) -> [String] { map.residents(of: id).map(\.name) }

        var result: [SettingsNode] = []
        let here = map.nodes.first { $0.kind == .thisMac }
        result.append(SettingsNode(id: DeviceMap.thisMacID, kind: .thisDevice, name: here?.name ?? "", state: .ready,
                                   imps: imps(on: DeviceMap.thisMacID), sleeping: sleeping))
        result.append(SettingsNode(id: "brains", kind: .brains, name: "", state: prefs.ai.services.isEmpty ? .needsSetup : .ready))
        result.append(SettingsNode(id: "tools", kind: .tools, name: "", state: prefs.mcpServers.contains { $0.isEnabled } ? .ready : .off))
        result.append(SettingsNode(id: "den", kind: .den, name: "", state: serverState(prefs.den, .den)))
        result.append(SettingsNode(id: "hop", kind: .hop, name: "", state: serverState(prefs.hop, .hop),
                                   isLocal: ServerKind.isOnThisDevice(prefs.hop)))
        for node in map.nodes where node.kind == .mac || node.kind == .phone {
            let channel = map.channels.first { $0.to == node.id }
            let seen = node.state == .connected
            result.append(SettingsNode(id: node.id, kind: node.kind == .phone ? .phone : .desktop, name: node.name,
                                       state: seen ? .ready : .offline, imps: imps(on: node.id),
                                       seen: seen, toolsHere: seen && node.isTrusted, via: channel?.server))
        }
        return result
    }

    public static func serverState(_ text: String, _ kind: ServerKind) -> SettingsNode.State {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .off }
        return kind.problem(with: text) == nil ? .ready : .needsSetup
    }

    /// The sections that have something to fix, for the mark on their place in the rail.
    public static func attentionGroups(_ items: [AttentionItem]) -> Set<SettingsGroup> {
        Set(items.map(\.group))
    }

    /// What needs fixing in one section, for the notice at the top of its page.
    public static func attention(_ nodes: [SettingsNode], in group: SettingsGroup) -> [AttentionItem] {
        attention(nodes).filter { $0.group == group }
    }

    /// What needs fixing, in a calm order: Brains, then the servers, then devices. Each item belongs
    /// to the section that fixes it: Brains, Sharing (the Den) or Devices (the Hop and linked devices).
    public static func attention(_ nodes: [SettingsNode]) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if nodes.contains(where: { $0.kind == .brains && $0.state == .needsSetup }) {
            items.append(AttentionItem(reason: .noBrains, group: .brains))
        }
        for name in nodes.filter({ $0.kind == .thisDevice }).flatMap(\.sleeping) {
            items.append(AttentionItem(reason: .noBrain(name), group: .brains))
        }
        for kind in [SettingsNode.Kind.den, .hop] {
            if nodes.contains(where: { $0.kind == kind && ($0.state == .off || $0.state == .needsSetup) }) {
                items.append(kind == .den ? AttentionItem(reason: .denNotSet, group: .sharing)
                                          : AttentionItem(reason: .hopNotSet, group: .devices))
            }
        }
        for node in nodes where (node.kind == .desktop || node.kind == .phone) && node.state == .offline {
            items.append(AttentionItem(reason: .deviceOffline(node.name), group: .devices))
        }
        return items
    }
}
