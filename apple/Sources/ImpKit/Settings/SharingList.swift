import Foundation

/// A trigger on the Sharing page: whose it is (`owner`, nil for one every Imp answers to).
public struct SharedTrigger: Hashable, Sendable, Identifiable {
    public let shortcut: Shortcut
    public let owner: UUID?
    public var id: UUID { shortcut.id }
}

/// An animation on the Sharing page: whose it is (`owner`, nil for one every Imp plays).
public struct SharedAnimation: Hashable, Sendable, Identifiable {
    public let animation: MadeAnimation
    public let owner: UUID?
    public var id: UUID { animation.id }
}

/// An MCP server on the Sharing page and the Imps that use it, in the order of the Imps.
public struct SharedServer: Hashable, Sendable, Identifiable {
    public let server: MCPServerConfig
    public let users: [UUID]
    public var id: UUID { server.id }
}

/// Everything that can be shared, gathered for Settings > Sharing: the shared items first, then each
/// Imp's own in the order of `imps`, and by name (numbers in order: "Wave 2" before "Wave 10") within a group.
/// Items of an Imp that no longer exists are left out.
extension ImpPreferences {
    public var sharableTriggers: [SharedTrigger] {
        grouped(shortcuts, owner: \.performer, name: \.name).map { SharedTrigger(shortcut: $0.0, owner: $0.1) }
    }

    public var sharableAnimations: [SharedAnimation] {
        let own = imps.flatMap { imp in imp.animations.map { ($0, Optional(imp.id)) } }
        let all = animationLibrary.map { ($0, UUID?.none) } + own
        return ordered(all, name: { $0.title }).map { SharedAnimation(animation: $0.0, owner: $0.1) }
    }

    public var sharableServers: [SharedServer] {
        mcpServers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { server in SharedServer(server: server, users: imps.filter { $0.servers.contains(server.id) }.map(\.id)) }
    }

    /// Switches a listed trigger on or off where it is kept: for every Imp when it is shared, for its Imp when it is its own.
    public mutating func setEnabled(_ on: Bool, trigger item: SharedTrigger) {
        guard var s = shortcuts.first(where: { $0.id == item.id }) else { return }
        s.isEnabled = on
        saveTrigger(s, for: item.owner.map(ScopeTarget.imp) ?? .everyImp)
    }

    /// Switches an MCP server on or off for every Imp.
    public mutating func setEnabled(_ on: Bool, server id: UUID) {
        guard let i = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[i].isEnabled = on
    }

    /// One kit of `triggers`, with the made animations they play (see `kit(sharing:named:imp:)`).
    public func kit(sharing triggers: [Shortcut], named name: String) -> Kit {
        var kit = Kit(name: name, triggers: triggers)
        for trigger in triggers {
            for animation in self.kit(sharing: trigger, named: name, imp: nil).animations
            where !kit.animations.contains(where: { $0.name == animation.name }) {
                kit.animations.append(animation)
            }
        }
        return kit
    }

    private func grouped(_ items: [Shortcut], owner: KeyPath<Shortcut, UUID?>, name: KeyPath<Shortcut, String>) -> [(Shortcut, UUID?)] {
        ordered(items.map { ($0, $0[keyPath: owner]) }, name: { $0[keyPath: name] })
    }

    /// Shared first, then by Imp in `imps` order, each group by name. Orphans are dropped.
    private func ordered<T>(_ items: [(T, UUID?)], name: (T) -> String) -> [(T, UUID?)] {
        let rank = Dictionary(uniqueKeysWithValues: imps.enumerated().map { ($1.id, $0 + 1) })
        let keyed = items.enumerated().compactMap { offset, item -> (Int, Int, String, (T, UUID?))? in
            guard let owner = item.1 else { return (0, offset, name(item.0), item) }
            return rank[owner].map { ($0, offset, name(item.0), item) }
        }
        return keyed.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            let order = a.2.localizedStandardCompare(b.2)
            return order == .orderedSame ? a.1 < b.1 : order == .orderedAscending
        }.map(\.3)
    }
}
