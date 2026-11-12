import CoreGraphics
import Foundation
import ImpCore

/// The Devices tab's picture of the system, built from what the link knows: the devices as nodes, the
/// channels between them (on the local network or through a server) with their state, and each Imp
/// with the tools it has and the Imps it can talk to. A pure value, so the view only draws it.
public struct DeviceMap: Equatable, Sendable, Decodable {
    public enum NodeKind: String, Sendable, Decodable { case thisMac = "thisDevice", mac, phone, server }
    public enum Path: String, Sendable, Decodable { case local, relay }
    public enum State: String, Sendable, Decodable { case connected, connecting, offline }

    /// What the link says about a linked device.
    public struct Peer: Equatable, Sendable, Encodable {
        public enum Reach: String, Sendable, Codable { case direct, viaServer, connecting, away }
        public var id: UUID
        public var name: String
        public var kind: LinkKind
        public var reach: Reach
        public var isTrusted: Bool
        /// The Imps on its screen right now, as it last said (`LinkMessage.stage`): its own and its
        /// visitors. Empty while it isn't connected.
        public var stage: [LinkStaged]
        public init(id: UUID, name: String, kind: LinkKind, reach: Reach, isTrusted: Bool = false, stage: [LinkStaged] = []) {
            self.id = id; self.name = name; self.kind = kind; self.reach = reach; self.isTrusted = isTrusted; self.stage = stage
        }
    }

    public struct Node: Equatable, Sendable, Identifiable, Decodable {
        public var id: String
        public var kind: NodeKind
        public var name: String
        public var isTrusted = false
        /// For a server: connected when a channel runs through it right now.
        public var state: State
        /// The Imps of this Mac that are on this device right now.
        public var imps: [UUID] = []
    }

    /// An Imp an Imp can message: one of this Mac's, or another device's Imp on the same screen.
    public struct Contact: Equatable, Sendable, Identifiable, Decodable {
        public var id: UUID
        public var name: String
        public var hue: Double
        /// The node its body is on.
        public var location: String
    }

    /// A way two devices talk. A relay channel passes through the server node `via`.
    public struct Channel: Equatable, Sendable, Identifiable, Decodable {
        public var id: String
        public var from: String
        public var to: String
        public var path: Path
        public var state: State
        public var via: String?
        /// The server's name when the channel goes through one.
        public var server: String?
    }

    public struct Tool: Equatable, Sendable, Identifiable, Codable {
        public enum Source: String, Sendable, Codable { case own, mcp }
        public var id: String
        public var title: String
        public var symbol: String
        public var source: Source
    }

    public struct ImpEntry: Equatable, Sendable, Identifiable, Decodable {
        public var id: UUID
        public var name: String
        public var hue: Double
        /// The node it is on.
        public var location: String
        public var tools: [Tool]
        /// The other Imps it can message (empty without the "Other Imps" tools): this Mac's own,
        /// wherever they are, and every Imp on the screen its body is on (`LinkTalks.targets`).
        public var talksTo: [Contact]
    }

    public var nodes: [Node]
    public var channels: [Channel]
    public var imps: [ImpEntry]
    /// Other devices' Imps on the screens this Mac knows: on a connected device, or visiting here.
    public var others: [Contact]

    public static let thisMacID = linkMapIds().thisDevice
    public static let serverID = linkMapIds().server

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func imp(_ id: UUID) -> ImpEntry? { imps.first { $0.id == id } }

    /// Every Imp whose body is on node `id`: this Mac's and other devices'.
    public func residents(of id: String) -> [Contact] {
        imps.filter { $0.location == id }.map { Contact(id: $0.id, name: $0.name, hue: $0.hue, location: id) }
            + others.filter { $0.location == id }
    }

    /// Builds the map in the core. `server` is the address the person set (empty or invalid: none). `visitors`
    /// are the Imps of other devices visiting this Mac's desktop.
    public static func build(thisMac: String, peers: [Peer], server: String,
                             imps: [ImpProfile], mcpServers: [MCPServerConfig], visitors: [LinkStaged] = []) -> DeviceMap {
        struct Entry: Encodable {
            var id: UUID
            var name: String
            var hue: Double
            var awayOn: UUID?
            var canTalk: Bool
            var tools: [Tool]
        }
        let entries = imps.map {
            Entry(id: $0.id, name: $0.name, hue: $0.hue, awayOn: $0.awayOn, canTalk: $0.uses(.troupe),
                  tools: tools(of: $0, servers: mcpServers))
        }
        let encoder = JSONEncoder()
        func text<T: Encodable>(_ value: T) -> String { (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]" }
        guard let json = try? linkDeviceMap(thisDevice: thisMac, peers: text(peers), server: server, imps: text(entries),
                                            visitors: text(visitors)),
              let map = try? JSONDecoder().decode(DeviceMap.self, from: Data(json.utf8)) else {
            return DeviceMap(nodes: [], channels: [], imps: [], others: [])
        }
        return map
    }

    /// The tools an Imp has, by group and by tool server. The one place that knows how to list them,
    /// so it can read from the tool registry once there is one.
    public static func tools(of imp: ImpProfile, servers: [MCPServerConfig]) -> [Tool] {
        var tools = ImpToolGroup.allCases.filter(imp.uses).map {
            Tool(id: ToolRegistry.ownGroupID($0), title: $0.title, symbol: $0.symbol, source: .own)
        }
        for server in servers where imp.servers.contains(server.id) && server.isEnabled {
            tools.append(Tool(id: "mcp.\(server.id.uuidString)", title: server.name, symbol: "puzzlepiece.extension.fill", source: .mcp))
        }
        return tools
    }
}

// MARK: Drawing

extension DeviceMap {
    /// The parts of the line from `a` to `b` that lie outside every box.
    public static func pieces(from a: CGPoint, to b: CGPoint, outside boxes: [CGRect]) -> [(CGPoint, CGPoint)] {
        linkLinePieces(a: LinkPoint(x: a.x, y: a.y), b: LinkPoint(x: b.x, y: b.y),
                       boxes: boxes.map { LinkRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) })
            .map { (CGPoint(x: $0.from.x, y: $0.from.y), CGPoint(x: $0.to.x, y: $0.to.y)) }
    }
}
