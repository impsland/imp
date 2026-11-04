import CoreGraphics
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
        /// The Imps on its screen right now, as it last said (`LinkMessage.stage`): its own and its
        /// visitors. Empty while it isn't connected.
        public var stage: [LinkStaged]
        public init(id: UUID, name: String, kind: LinkKind, reach: Reach, isTrusted: Bool = false, stage: [LinkStaged] = []) {
            self.id = id; self.name = name; self.kind = kind; self.reach = reach; self.isTrusted = isTrusted; self.stage = stage
        }
    }

    public struct Node: Equatable, Sendable, Identifiable {
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
    public struct Contact: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var hue: Double
        /// The node its body is on.
        public var location: String
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
        /// The other Imps it can message (empty without the "Other Imps" tools): this Mac's own,
        /// wherever they are, and every Imp on the screen its body is on (`LinkTalks.targets`).
        public var talksTo: [Contact]
    }

    public var nodes: [Node]
    public var channels: [Channel]
    public var imps: [ImpEntry]
    /// Other devices' Imps on the screens this Mac knows: on a connected device, or visiting here.
    public var others: [Contact]

    public static let thisMacID = "this-mac"
    public static let serverID = "server"

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func imp(_ id: UUID) -> ImpEntry? { imps.first { $0.id == id } }

    /// Every Imp whose body is on node `id`: this Mac's and other devices'.
    public func residents(of id: String) -> [Contact] {
        imps.filter { $0.location == id }.map { Contact(id: $0.id, name: $0.name, hue: $0.hue, location: id) }
            + others.filter { $0.location == id }
    }

    /// Builds the map. `server` is the address the person set (empty or invalid: none). `visitors`
    /// are the Imps of other devices visiting this Mac's desktop.
    public static func build(thisMac: String, peers: [Peer], server: String,
                             imps: [ImpProfile], mcpServers: [MCPServerConfig], visitors: [LinkStaged] = []) -> DeviceMap {
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
        // Other devices' Imps on each screen: on a connected device (its own and its visitors), and
        // the visitors on this Mac's desktop. This Mac's own Imps are listed once, where they are.
        let mine = Set(imps.map(\.id))
        var screens: [String: [LinkStaged]] = [thisMacID: visitors.filter { !mine.contains($0.id) }]
        for peer in sorted where peer.reach != .away {
            screens[peer.id.uuidString] = peer.stage.filter { !mine.contains($0.id) }
        }
        var others: [Contact] = []
        var location: [UUID: String] = [:]
        for node in nodes {
            for staged in screens[node.id] ?? [] where location[staged.id] == nil {
                location[staged.id] = node.id
                others.append(Contact(id: staged.id, name: staged.imp.name, hue: staged.imp.hue, location: node.id))
            }
        }
        for imp in imps { location[imp.id] = here(imp) }

        // Who each can message, by the link's own rule: the Imps of its home, and the Imps on the
        // screen its body is on (`LinkTalks.targets`).
        let home = imps.map { LinkStaged(imp: LinkImp($0), home: UUID(uuid: UUID_NULL)) }
        let entries = imps.map { imp in
            let reachable = imp.uses(.troupe)
                ? LinkTalks.targets(of: imp.id, mine: home, stage: screens[here(imp)] ?? [])
                : []
            return ImpEntry(id: imp.id, name: imp.name, hue: imp.hue, location: here(imp),
                            tools: tools(of: imp, servers: mcpServers),
                            talksTo: reachable.map { Contact(id: $0.id, name: $0.imp.name, hue: $0.imp.hue, location: location[$0.id] ?? thisMacID) })
        }
        return DeviceMap(nodes: nodes, channels: channels, imps: entries, others: others)
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

// MARK: Drawing

extension DeviceMap {
    /// The parts of the line from `a` to `b` that lie outside every box.
    public static func pieces(from a: CGPoint, to b: CGPoint, outside boxes: [CGRect]) -> [(CGPoint, CGPoint)] {
        let dx = b.x - a.x, dy = b.y - a.y
        // Where along the line (0 at a, 1 at b) it is inside each box (Liang-Barsky).
        var covered: [ClosedRange<CGFloat>] = []
        for box in boxes {
            var low: CGFloat = 0, high: CGFloat = 1
            var inside = true
            for (p, q) in [(-dx, a.x - box.minX), (dx, box.maxX - a.x), (-dy, a.y - box.minY), (dy, box.maxY - a.y)] {
                if p == 0 {
                    if q < 0 { inside = false; break }
                } else {
                    let t = q / p
                    if p < 0 { low = max(low, t) } else { high = min(high, t) }
                }
            }
            if inside, low < high { covered.append(low...high) }
        }
        var result: [(CGPoint, CGPoint)] = []
        var from: CGFloat = 0
        func point(_ t: CGFloat) -> CGPoint { CGPoint(x: a.x + dx * t, y: a.y + dy * t) }
        for range in covered.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > from { result.append((point(from), point(range.lowerBound))) }
            from = max(from, range.upperBound)
        }
        if from < 1 { result.append((point(from), point(1))) }
        return result
    }
}
