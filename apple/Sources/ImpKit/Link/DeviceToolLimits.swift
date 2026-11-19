import Foundation

/// Which tool groups the Imps of this Mac may use for a linked device, set per device.
///
/// An Imp of this Mac that another device holds answers that device's asks here, with this Mac's tools.
/// A device that isn't marked Mine gets no tools at all (`AskOrigin`). A device that is gets the Imp's own
/// tools, less the groups switched off for it here. Groups are named by their registry id: an own group by
/// `ToolRegistry.ownGroupID`, the commands tool by `commands`, an MCP server by `groupID(server:)`
/// (the same ids `DeviceMap.Tool` has). Nothing is switched off until someone does it.
public struct DeviceToolLimits: Codable, Hashable, Sendable {
    /// The id of the tool that runs commands on this Mac (`ImpProfile.usesShell`).
    public static let commands = "shell"

    /// The id of a group of the Imp's own tools.
    public static func groupID(_ group: ImpToolGroup) -> String { ToolRegistry.ownGroupID(group) }

    /// The id of an MCP server's tools.
    public static func groupID(server: UUID) -> String { "mcp.\(server.uuidString)" }

    /// The group ids switched off, by device id (a UUID's text, so the stored settings are plain JSON).
    private var off: [String: [String]] = [:]

    public init() {}

    /// The groups switched off for `device`.
    public func limited(on device: UUID) -> Set<String> { Set(off[device.uuidString] ?? []) }

    public func isAllowed(group: String, on device: UUID) -> Bool { !limited(on: device).contains(group) }

    /// Whether anything is switched off for `device`.
    public func hasLimits(on device: UUID) -> Bool { off[device.uuidString]?.isEmpty == false }

    /// Switches a group on or off for a device. A device with nothing off is not stored.
    public mutating func set(_ allowed: Bool, group: String, on device: UUID) {
        var groups = limited(on: device)
        if allowed { groups.remove(group) } else { groups.insert(group) }
        off[device.uuidString] = groups.isEmpty ? nil : groups.sorted()
    }

    /// The device was forgotten: its limits go with it.
    public mutating func forget(device: UUID) { off[device.uuidString] = nil }

    public mutating func forgetAll() { off = [:] }

    /// `profile` with the groups and servers switched off for `device` taken away, so the usual tool
    /// selection (`Assistant.tools(for:)`) is the only filter.
    public func profile(_ profile: ImpProfile, limitedOn device: UUID) -> ImpProfile {
        let groups = limited(on: device)
        guard !groups.isEmpty else { return profile }
        var limited = profile
        for group in ImpToolGroup.allCases where groups.contains(Self.groupID(group)) { limited.setUses(group, false) }
        if groups.contains(Self.commands) { limited.usesShell = false }
        limited.servers.removeAll { groups.contains(Self.groupID(server: $0)) }
        return limited
    }
}

/// Who asked one of this Mac's Imps, when it wasn't asked here: a linked device, by its Imp or the
/// person. What the Imp may use to answer is decided from it, in one place.
public struct AskOrigin: Equatable, Sendable {
    public var device: UUID
    public var name: String
    /// One of the owner's own devices (marked Mine).
    public var trusted: Bool

    public init(device: UUID, name: String, trusted: Bool) {
        self.device = device; self.name = name; self.trusted = trusted
    }

    /// The Imp as it answers this ask: nil for a device that isn't trusted (plain conversation, nothing
    /// that acts), else `profile` less the tools switched off for the device.
    public func profile(_ profile: ImpProfile, limits: DeviceToolLimits) -> ImpProfile? {
        trusted ? limits.profile(profile, limitedOn: device) : nil
    }
}
