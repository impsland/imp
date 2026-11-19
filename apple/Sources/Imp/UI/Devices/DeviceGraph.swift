import CoreGraphics
import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// The Devices screen as a graph for the canvas: a pure mapping from what `DeviceMap` knows to SwiftFlow's nodes
/// and edges, with their first places. The canvas only draws it, so the shape of the graph is tested.
///
/// A device (This Mac, a linked device, the Hop) is a group node; an Imp whose body is on a device is a child
/// node inside it, in a grid. A channel is an edge between two devices; one through the Hop is two edges, to the
/// Hop and from it. An Imp that is away from its home is tied to the home device by a tether. This Mac is on the
/// leading side, the Hop in the middle and the linked devices on the trailing side, one under the other.
/// Where a device was dragged to is remembered by the caller and passed in as `moved`, so a refresh of the
/// link never puts it back.
enum DeviceGraph {
    typealias FlowNode = Node<NodeData>
    typealias LinkEdge = FlowEdge<EdgeData>

    /// How big things are, in the canvas's own units.
    enum Metrics {
        static let padding: CGFloat = 14
        /// The name and kind at the top of a device, above its Imps.
        static let header: CGFloat = 54
        static let minimumWidth: CGFloat = 210
        static let maximumWidth: CGFloat = 380
        /// An Imp's chip: as narrow as this at the least (it takes what its device gives it), and this tall.
        static let chipMinimum: CGFloat = 104
        static let chipHeight: CGFloat = 34
        static let chipGap: CGFloat = 8
        static let maxChipColumns = 3
        /// How wide a character of a device's name is, a little generously so a name never truncates.
        static let titleCharacter: CGFloat = 8.2
        /// What the header needs besides the name: the picture, the state mark and the gaps.
        static let headerChrome: CGFloat = 2 * padding + 64
        static let columnGap: CGFloat = 190
        static let rowGap: CGFloat = 40
    }

    struct NodeData: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case device(DeviceMap.Node)
            case imp(DeviceMap.Contact, ours: Bool)
        }

        var role: Role
        /// How the Hop stands, for the Hop's node.
        var hop: HopStanding?
        /// What a screen reader says about it.
        var label: String
    }

    struct EdgeData: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A channel between two devices (`DeviceMap.Channel.id`); through the Hop it is the half from the Hop.
            case channel(String)
            /// The half of channels through the Hop that is shared: this Mac to the Hop (the Hop's id).
            case toHop(String)
            /// An Imp in a device that isn't its home, tied to its home.
            case tether(UUID, in: String)
        }

        enum Look: Hashable, Sendable {
            case local, hop
            case tether(hue: Double)
        }

        var kind: Kind
        var look: Look
        /// Not connected right now: drawn faded.
        var dimmed: Bool
        /// The short tag on the line: Wi-Fi, or the Hop's host.
        var tag: String?
        /// What a screen reader and the hover help say.
        var label: String
    }

    struct Graph: Equatable {
        var nodes: [FlowNode]
        var edges: [LinkEdge]

        /// The devices only: what the view fits in the window (their Imps are inside them).
        var devices: [FlowNode] { nodes.filter { $0.parentId == nil } }

        /// The sizes of every node, as set.
        var sizes: [String: CGSize] {
            Dictionary(uniqueKeysWithValues: nodes.compactMap { node in
                node.width.flatMap { width in node.height.map { (node.id, CGSize(width: width, height: $0)) } }
            })
        }
    }

    /// The id of an Imp's node: an Imp can be seen on more than one device.
    static func impNodeID(_ imp: UUID, in node: String) -> String { "\(node)/\(imp.uuidString)" }

    /// `hopText` is the Hop's address as set (empty is off); without it the Hop stands as the map says. The Hop
    /// is always on the canvas, set or not, so it can be opened to set one up.
    static func build(_ source: DeviceMap, hopText: String? = nil, moved: [String: CGPoint] = [:]) -> Graph {
        let map = source.withHop
        let standing = map.hopStanding(text: hopText ?? map.hopNode.addresses.first ?? "")
        let links = map.channels.filter { map.node($0.from) != nil && map.node($0.to) != nil }
        let hop: DeviceMap.Node? = map.hopNode
        let usesLocal = links.contains { $0.path == .local }

        // Sizes, then columns: This Mac, the Hop, the linked devices.
        var boxes: [String: CGSize] = [:]
        for node in map.nodes { boxes[node.id] = box(of: node, residents: map.residents(of: node.id).count) }
        let thisMac = map.nodes.filter { $0.kind == .thisMac }
        let linked = map.nodes.filter(\.isLinkedDevice)
        var columns: [[DeviceMap.Node]] = [thisMac]
        if let hop { columns.append([hop]) }
        columns.append(linked)

        var places: [String: CGPoint] = [:]
        let heights = columns.map { column in column.reduce(CGFloat(0)) { $0 + (boxes[$1.id]?.height ?? 0) } + gaps(column.count) }
        let tallest = heights.max() ?? 0
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() where !column.isEmpty {
            var y = (tallest - heights[index]) / 2
            for node in column {
                places[node.id] = CGPoint(x: x, y: y)
                y += (boxes[node.id]?.height ?? 0) + Metrics.rowGap
            }
            x += (column.compactMap { boxes[$0.id]?.width }.max() ?? 0) + Metrics.columnGap
        }
        // With local channels the Hop sits below the rest, out of their way, in the column between.
        if let hop, usesLocal, let place = places[hop.id] { places[hop.id] = CGPoint(x: place.x, y: tallest + Metrics.rowGap) }
        for (id, point) in moved where places[id] != nil { places[id] = point }

        func frame(_ id: String) -> CGRect {
            CGRect(origin: places[id] ?? .zero, size: boxes[id] ?? .zero)
        }

        var nodes: [FlowNode] = []
        var edges: [LinkEdge] = []
        for device in map.nodes {
            for contact in map.residents(of: device.id) {
                guard let home = contact.home, home != device.id, map.node(home) != nil else { continue }
                let side = tetherSide(from: frame(device.id), home: frame(home))
                edges.append(LinkEdge(
                    id: "tether/\(device.id)/\(contact.id.uuidString)", source: impNodeID(contact.id, in: device.id), target: home,
                    sourceHandle: Port.tether(side), targetHandle: Port.tether(side),
                    type: .bezier, deletable: false,
                    data: EdgeData(kind: .tether(contact.id, in: device.id), look: .tether(hue: contact.hue), dimmed: false, tag: nil,
                                   label: words("devices.tether.label", contact.name, map.title(of: device.id), map.title(of: home)))))
            }
        }

        for device in map.nodes {
            guard let place = places[device.id], let size = boxes[device.id] else { continue }
            nodes.append(FlowNode(
                id: device.id, position: XYPosition(x: place.x, y: place.y),
                data: NodeData(role: .device(device), hop: device.kind == .server ? standing : nil,
                               label: map.summary(of: device, standing: device.kind == .server ? standing : nil)), type: "group",
                width: size.width, height: size.height, draggable: true, selectable: false, connectable: false, deletable: false,
                sourcePosition: .right, targetPosition: .left))
            let slots = chipFrames(count: map.residents(of: device.id).count, in: size.width)
            for (index, contact) in map.residents(of: device.id).enumerated() {
                let ours = map.imp(contact.id) != nil
                let side = contact.home.flatMap { $0 != device.id && map.node($0) != nil ? tetherSide(from: frame(device.id), home: frame($0)) : nil }
                nodes.append(FlowNode(
                    id: impNodeID(contact.id, in: device.id),
                    position: XYPosition(x: slots[index].minX, y: slots[index].minY),
                    data: NodeData(role: .imp(contact, ours: ours), hop: nil,
                                   label: words(ours ? "devices.chip.label_ours" : "devices.chip.label_visitor", contact.name, map.title(of: device.id))),
                    parentId: device.id, width: slots[index].width, height: slots[index].height,
                    draggable: false, selectable: false, connectable: false, deletable: false,
                    sourcePosition: side ?? .bottom))
            }
        }

        var throughHop: Set<String> = []
        for channel in links {
            let faded = channel.state != .connected
            let label = words("devices.edge.label", map.title(of: channel.from), map.title(of: channel.to), map.route(of: channel), channel.state.word)
            let tag = map.tag(of: channel)
            if channel.path == .relay, let via = channel.via ?? hop?.id, map.node(via) != nil {
                if throughHop.insert(via).inserted {
                    edges.append(LinkEdge(
                        id: "hop/\(via)", source: channel.from, target: via, sourceHandle: Port.out, targetHandle: Port.in, type: .bezier, deletable: false,
                        data: EdgeData(kind: .toHop(via), look: .hop, dimmed: faded, tag: tag, label: words("devices.hop.edge.label", map.title(of: via), tag))))
                } else if !faded, let index = edges.firstIndex(where: { $0.id == "hop/\(via)" }) {
                    edges[index].data?.dimmed = false
                }
                edges.append(LinkEdge(
                    id: "channel/\(channel.id)", source: via, target: channel.to, sourceHandle: Port.out, targetHandle: Port.in, type: .bezier, deletable: false,
                    data: EdgeData(kind: .channel(channel.id), look: .hop, dimmed: faded, tag: nil, label: label)))
            } else {
                edges.append(LinkEdge(
                    id: "channel/\(channel.id)", source: channel.from, target: channel.to, sourceHandle: Port.out, targetHandle: Port.in, type: .bezier, deletable: false,
                    data: EdgeData(kind: .channel(channel.id), look: channel.path == .relay ? .hop : .local, dimmed: faded,
                                   tag: tag, label: label)))
            }
        }
        // Channels under tethers, so the thin line is not hidden by a thick one.
        for index in edges.indices where edges[index].data?.isTether == true { edges[index].zIndex = 1 }
        return Graph(nodes: nodes, edges: edges)
    }

    // MARK: Handles

    /// The points where lines attach. Channels run between the sides of devices (out on the right, in on the left);
    /// a tether leaves the bottom or top of its Imp's chip and arrives at the same side of its home, so it runs
    /// clear of the channels instead of along them.
    enum Port {
        static let out = "out"
        static let `in` = "in"
        static func tether(_ side: Position) -> String { "tether-\(side.rawValue)" }
        static let tetherSides: [Position] = [.top, .bottom]
    }

    /// Which side a tether uses: the top when its home is higher than the device the Imp is on, else the bottom.
    static func tetherSide(from device: CGRect, home: CGRect) -> Position {
        home.midY < device.midY ? .top : .bottom
    }

    /// Where a line's tag sits: clear of the line, a little to its upper side (to the right on a vertical one), so
    /// it never covers the line it names.
    static func tagCenter(source: CGPoint, target: CGPoint, mid: CGPoint, clearance: CGFloat) -> CGPoint {
        let dx = target.x - source.x, dy = target.y - source.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return CGPoint(x: mid.x, y: mid.y - clearance) }
        var normal = CGPoint(x: dy / length, y: -dx / length)
        if normal.y > 0 || (normal.y == 0 && normal.x < 0) { normal = CGPoint(x: -normal.x, y: -normal.y) }
        return CGPoint(x: mid.x + normal.x * clearance, y: mid.y + normal.y * clearance)
    }

    // MARK: Geometry

    private static func gaps(_ count: Int) -> CGFloat { CGFloat(max(0, count - 1)) * Metrics.rowGap }

    /// How many chips are in each row of a device `width` wide: as few rows as the width allows, balanced (four
    /// that need two rows go two and two), at most `maxChipColumns` across.
    static func chipRows(_ count: Int, in width: CGFloat) -> [Int] {
        let fit = Int((width - 2 * Metrics.padding + Metrics.chipGap) / (Metrics.chipMinimum + Metrics.chipGap))
        return RowBalance.lineLengths(count: count, fit: max(1, min(Metrics.maxChipColumns, fit)))
    }

    /// Where the chips of a device `width` wide are inside it, in order: every row spans the full inner width, the
    /// same inset from the edges as the header's, and its chips share it equally. The first row starts under the header.
    static func chipFrames(count: Int, in width: CGFloat) -> [CGRect] {
        let inner = width - 2 * Metrics.padding
        var frames: [CGRect] = []
        for (row, length) in chipRows(count, in: width).enumerated() {
            let n = CGFloat(length)
            let each = (inner - Metrics.chipGap * (n - 1)) / n
            let y = Metrics.header + CGFloat(row) * (Metrics.chipHeight + Metrics.chipGap)
            for column in 0..<length {
                frames.append(CGRect(x: Metrics.padding + CGFloat(column) * (each + Metrics.chipGap), y: y, width: each, height: Metrics.chipHeight))
            }
        }
        return frames
    }

    /// A device's size: as wide as its name needs and as its Imps need at their narrowest (at most three across), and
    /// no wider than `maximumWidth`; a single Imp fills the width of its device.
    static func box(of node: DeviceMap.Node, residents count: Int) -> CGSize {
        let across = CGFloat(min(Metrics.maxChipColumns, count))
        let imps = count > 0 ? 2 * Metrics.padding + across * Metrics.chipMinimum + (across - 1) * Metrics.chipGap : 0
        let name = Metrics.headerChrome + CGFloat(node.title.count) * Metrics.titleCharacter
        let width = min(Metrics.maximumWidth, max(Metrics.minimumWidth, name, imps))
        guard count > 0 else { return CGSize(width: width, height: Metrics.header) }
        let rows = CGFloat(chipRows(count, in: width).count)
        return CGSize(width: width, height: Metrics.header + rows * Metrics.chipHeight + (rows - 1) * Metrics.chipGap + Metrics.padding)
    }
}

extension DeviceGraph.EdgeData {
    var isTether: Bool { if case .tether = kind { true } else { false } }
}

extension DeviceGraph.Graph {
    struct Openable: Identifiable {
        var label: String
        var sheet: DevicesSheet
        var id: DevicesSheet { sheet }
    }

    /// What a click on a node opens.
    func sheet(ofNode id: String) -> DevicesSheet? {
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        switch node.data.role {
        case .device(let device): return .opening(.node(device.id))
        case .imp(let contact, _): return node.parentId.map { .opening(.imp(contact.id, in: $0)) }
        }
    }

    /// What a click on an edge opens: a channel, the Hop for the half that is shared, or a tether.
    func sheet(ofEdge id: String) -> DevicesSheet? {
        guard let kind = edges.first(where: { $0.id == id })?.data?.kind else { return nil }
        return .opening(DeviceSelection(kind))
    }

    /// Everything that can be opened, in reading order, for a screen reader and the keyboard.
    var openable: [Openable] {
        let devices = nodes.filter { $0.parentId == nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let imps = nodes.filter { $0.parentId != nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let lines = edges.compactMap { edge in edge.data.flatMap { data in sheet(ofEdge: edge.id).map { Openable(label: data.label, sheet: $0) } } }
        return devices + imps + lines
    }
}
