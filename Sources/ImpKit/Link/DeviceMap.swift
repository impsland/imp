import Foundation

/// The Devices tab's picture of the system, built from what the link knows: the devices as nodes, the
/// channels between them (on the local network or through a server) with their state, and each Imp
/// with the tools it has and the Imps it can talk to. A pure value, so the view only draws it.
public struct DeviceMap: Equatable, Sendable {
    public enum NodeKind: String, Sendable { case thisMac, mac, phone, server }
    public enum Path: String, Sendable { case local, relay }
    public enum State: String, Sendable { case connected, connecting, offline }

    /// What the link says about a linked device.
    public struct Peer: Equatable, Sendable {
        public enum Reach: Sendable { case direct, viaServer, connecting, away }
        public var id: UUID
        public var name: String
        public var kind: LinkKind
        public var reach: Reach
        public var isTrusted: Bool
        public init(id: UUID, name: String, kind: LinkKind, reach: Reach, isTrusted: Bool = false) {
            self.id = id; self.name = name; self.kind = kind; self.reach = reach; self.isTrusted = isTrusted
        }
    }

    public struct Node: Equatable, Sendable, Identifiable {
        public var id: String
        public var kind: NodeKind
        public var name: String
        public var isTrusted = false
        /// For a server: connected when a channel runs through it right now.
        public var state: State
        /// The Imps that are on this device right now.
        public var imps: [UUID] = []
    }

    /// A way two devices talk. A relay channel passes through the server node `via`.
    public struct Channel: Equatable, Sendable, Identifiable {
        public var id: String
        public var from: String
        public var to: String
        public var path: Path
        public var state: State
        public var via: String?
        /// The server's name when the channel goes through one.
        public var server: String?
    }

    public struct Tool: Equatable, Sendable, Identifiable {
        public enum Source: String, Sendable { case own, mcp }
        public var id: String
        public var title: String
        public var symbol: String
        public var source: Source
    }

    public struct ImpEntry: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var hue: Double
        /// The node it is on.
        public var location: String
        public var tools: [Tool]
        /// The other Imps it can message (empty without the "Other Imps" tools).
        public var talksTo: [UUID]
    }

    public var nodes: [Node]
    public var channels: [Channel]
    public var imps: [ImpEntry]

    public static let thisMacID = "this-mac"
    public static let serverID = "server"

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func imp(_ id: UUID) -> ImpEntry? { imps.first { $0.id == id } }

    /// Builds the map. `server` is the address the person set (empty or invalid: none).
    public static func build(thisMac: String, peers: [Peer], server: String,
                             imps: [ImpProfile], mcpServers: [MCPServerConfig]) -> DeviceMap {
        let serverName = ImpServer(server)?.hopHost
        let sorted = peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func here(_ imp: ImpProfile) -> String {
            imp.awayOn.flatMap { holder in peers.contains { $0.id == holder } ? holder.uuidString : nil } ?? thisMacID
        }
        func held(_ id: String) -> [UUID] { imps.filter { here($0) == id }.map(\.id) }

        var nodes = [Node(id: thisMacID, kind: .thisMac, name: thisMac, state: .connected, imps: held(thisMacID))]
        var channels: [Channel] = []
        var relayUp = false
        for peer in sorted {
            let id = peer.id.uuidString
            let state: State = switch peer.reach {
            case .direct, .viaServer: .connected
            case .connecting: .connecting
            case .away: .offline
            }
            // A device that is away is shown on the path it would come back on.
            let relay = peer.reach == .viaServer || (peer.reach != .direct && serverName != nil)
            if peer.reach == .viaServer { relayUp = true }
            nodes.append(Node(id: id, kind: peer.kind == .mac ? .mac : .phone, name: peer.name,
                              isTrusted: peer.isTrusted, state: state, imps: held(id)))
            channels.append(Channel(id: id, from: thisMacID, to: id, path: relay ? .relay : .local, state: state,
                                    via: relay ? serverID : nil, server: relay ? serverName : nil))
        }
        if let serverName {
            nodes.insert(Node(id: serverID, kind: .server, name: serverName, state: relayUp ? .connected : .offline), at: 1)
        }
        let entries = imps.map { imp in
            ImpEntry(id: imp.id, name: imp.name, hue: imp.hue, location: here(imp),
                     tools: tools(of: imp, servers: mcpServers),
                     talksTo: imp.uses(.troupe) ? imps.filter { $0.id != imp.id }.map(\.id) : [])
        }
        return DeviceMap(nodes: nodes, channels: channels, imps: entries)
    }

    /// The tools an Imp has, by group and by tool server. The one place that knows how to list them,
    /// so it can read from the tool registry once there is one.
    public static func tools(of imp: ImpProfile, servers: [MCPServerConfig]) -> [Tool] {
        var tools = ImpToolGroup.allCases.filter(imp.uses).map {
            Tool(id: "own.\($0.rawValue)", title: $0.title, symbol: $0.symbol, source: .own)
        }
        for server in servers where imp.servers.contains(server.id) && server.isEnabled {
            tools.append(Tool(id: "mcp.\(server.id.uuidString)", title: server.name, symbol: "puzzlepiece.extension.fill", source: .mcp))
        }
        return tools
    }
}
