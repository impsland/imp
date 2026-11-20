import CoreGraphics
import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// The Devices screen as a graph for the canvas: a pure mapping from what `DeviceMap` knows to SwiftFlow's nodes
/// and edges, with their first places. The canvas only draws it, so the shape of the graph is tested.
///
/// A device (This Mac, a linked device, the Hop) is a group node. An Imp whose body is on a device is a child
/// node inside it, in a grid. A channel is an edge between two devices. One through the Hop is two edges, to the
/// Hop and from it. An Imp that is away from its home is tied to the home device by a tether, and an Imp that can
/// talk to Imps on other devices has a talk edge to each, hidden until it is in focus. This Mac is in the middle,
/// the linked devices are on its two sides (each next to the shorter side, so the picture stays balanced) and the
/// Hop, only when a channel goes through it, is above This Mac. Where a device was dragged to is remembered by the
/// caller and passed in as `moved`, so a refresh of the link never puts it back.
enum DeviceGraph {
    typealias FlowNode = Node<NodeData>
    typealias LinkEdge = FlowEdge<EdgeData>

    /// How big things are, in the canvas's own units.
    enum Metrics {
        static let padding: CGFloat = 12
        /// The name and kind at the top of a device, above its Imps.
        static let header: CGFloat = 44
        static let minimumWidth: CGFloat = 190
        static let maximumWidth: CGFloat = 340
        /// An Imp's chip: as narrow as this at the least (it takes what its device gives it), and this tall.
        static let chipMinimum: CGFloat = 100
        static let chipHeight: CGFloat = 28
        static let chipGap: CGFloat = 6
        /// How wide a character of an Imp's name is in its chip, and what the chip needs besides the name: the
        /// insets, its colour dot, and room for the away mark so that never takes the name's.
        static let chipCharacter: CGFloat = 7.5
        static let chipChrome: CGFloat = 62
        static let maxChipColumns = 3
        /// How wide a character of a device's name is, a little generously so a name never truncates.
        static let titleCharacter: CGFloat = 8.2
        /// What the header needs besides the name: the picture, the state mark and the gaps.
        static let headerChrome: CGFloat = 2 * padding + 56
        static let columnGap: CGFloat = 150
        static let rowGap: CGFloat = 28
        /// How wide a line's clickable band is.
        static let interactionWidth: CGFloat = 26
    }

    struct NodeData: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case device(DeviceMap.Node)
            case imp(DeviceMap.Contact, ours: Bool)
        }

        var role: Role
        /// How the Hop stands, for the Hop's node.
        var hop: HopStanding?
        /// An Imp whose body is not where it thinks (not on its home device): it gets a small mark.
        var away = false
        /// What a screen reader says about it.
        var label: String
    }

    struct EdgeData: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A channel between two devices (`DeviceMap.Channel.id`). Through the Hop it is the half from the Hop.
            case channel(String)
            /// The half of channels through the Hop that is shared: this Mac to the Hop (the Hop's id).
            case toHop(String)
            /// An Imp in a device that isn't its home, tied to its home.
            case tether(UUID, in: String)
            /// An Imp (first) that can message another device's Imp (second). Shown only while the first is in focus.
            case talk(UUID, UUID)
        }

        enum Look: Hashable, Sendable {
            case local, hop
            case tether(hue: Double)
            case talk(hue: Double)
        }

        /// How a channel is travelled, for the glyph on its badge.
        enum Route: Hashable, Sendable { case local, hop }

        var kind: Kind
        var look: Look
        /// Not connected right now: drawn faded.
        var dimmed: Bool
        /// Something flows on it right now: a connected channel, a tether to a device that is there.
        var live = false
        var route: Route?
        /// The symbols of the plugs that are in for the device at the far end, the trust first. Empty when none is.
        var access: [String] = []
        /// The far device is not Mine, so nothing is plugged in (the badge shows a lock).
        var locked = false
        /// The devices this line is between (a tether: where the Imp is and its home).
        var ends: [String] = []
        /// The Hop a channel goes through, when it does.
        var via: String?
        /// What a screen reader and the hover help say.
        var label: String
    }

    /// What the canvas puts in the light: everything else is drawn dimmed.
    enum Focus: Hashable, Sendable {
        case imp(UUID, in: String)
        case device(String)
        case channel(String)

        /// The focus of an open sheet's selection.
        init(_ selection: DeviceSelection) {
            switch selection {
            case .node(let id): self = .device(id)
            case .imp(let id, let node): self = .imp(id, in: node)
            case .channel(let id): self = .channel(id)
            }
        }

        /// The focus of an open sheet. The Link sheet is about no one thing.
        init?(_ sheet: DevicesSheet) {
            switch sheet {
            case .about(let selection): self.init(selection)
            case .hop: self = .device(DeviceMap.serverID)
            case .link: return nil
            }
        }
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

    /// `hopText` is the Hop's address as set (empty is off). Without it the Hop stands as the map says. The Hop is
    /// on the canvas only when a channel goes through it. `access` is what each linked device may do (by node id);
    /// a device without an entry is plugged with its trust only. Talk edges are
    /// all there but hidden; `revealing(talkOf:)` shows an Imp's.
    static func build(_ map: DeviceMap, hopText: String? = nil, access: [String: DeviceAccess] = [:],
                      moved: [String: CGPoint] = [:]) -> Graph {
        let hopUsed = map.hopInUse
        let standing = map.hopStanding(text: hopText ?? map.hop?.addresses.first ?? "")
        let shown = map.nodes.filter { $0.kind != .server || hopUsed }
        let links = map.channels.filter { map.node($0.from) != nil && map.node($0.to) != nil }

        // Sizes, then columns: This Mac in the middle, the linked devices on both sides, the Hop above This Mac.
        var boxes: [String: CGSize] = [:]
        for node in shown { boxes[node.id] = box(of: node, residents: map.residents(of: node.id).count,
                                       longestName: map.residents(of: node.id).map(\.name.count).max() ?? 0) }
        func height(_ node: DeviceMap.Node) -> CGFloat { boxes[node.id]?.height ?? 0 }
        func width(_ node: DeviceMap.Node) -> CGFloat { boxes[node.id]?.width ?? 0 }
        let thisMac = shown.first { $0.kind == .thisMac }
        let hop = shown.first { $0.kind == .server }
        var trailing: [DeviceMap.Node] = [], leading: [DeviceMap.Node] = []
        var trailingHeight: CGFloat = 0, leadingHeight: CGFloat = 0
        for device in shown.filter(\.isLinkedDevice) {
            if trailingHeight <= leadingHeight {
                trailing.append(device); trailingHeight += height(device) + Metrics.rowGap
            } else {
                leading.append(device); leadingHeight += height(device) + Metrics.rowGap
            }
        }
        let leadingWidth = leading.map(width).max() ?? 0
        let middleWidth = max(thisMac.map(width) ?? 0, hop.map(width) ?? 0)
        let middleX = leading.isEmpty ? 0 : leadingWidth + Metrics.columnGap
        let trailingX = middleX + middleWidth + Metrics.columnGap

        var places: [String: CGPoint] = [:]
        let macHeight = thisMac.map(height) ?? 0
        if let thisMac { places[thisMac.id] = CGPoint(x: middleX + (middleWidth - width(thisMac)) / 2, y: 0) }
        if let hop { places[hop.id] = CGPoint(x: middleX + (middleWidth - width(hop)) / 2, y: -(height(hop) + Metrics.rowGap)) }
        func stack(_ column: [DeviceMap.Node], x: (DeviceMap.Node) -> CGFloat) {
            var y = macHeight / 2 - (column.reduce(CGFloat(0)) { $0 + height($1) } + gaps(column.count)) / 2
            for node in column {
                places[node.id] = CGPoint(x: x(node), y: y)
                y += height(node) + Metrics.rowGap
            }
        }
        stack(leading) { leadingWidth - width($0) }
        stack(trailing) { _ in trailingX }
        // Start at the origin, so the same map always has the same first places.
        let origin = CGPoint(x: places.values.map(\.x).min() ?? 0, y: places.values.map(\.y).min() ?? 0)
        for (id, point) in places { places[id] = CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
        for (id, point) in moved where places[id] != nil { places[id] = point }

        func frame(_ id: String) -> CGRect { CGRect(origin: places[id] ?? .zero, size: boxes[id] ?? .zero) }
        func hasChip(_ contact: UUID, on node: String) -> Bool { map.residents(of: node).contains { $0.id == contact } }

        var nodes: [FlowNode] = []
        var edges: [LinkEdge] = []
        for device in shown {
            for contact in map.residents(of: device.id) {
                guard let home = contact.home, home != device.id, map.node(home) != nil, boxes[home] != nil else { continue }
                let side = tetherSide(from: frame(device.id), home: frame(home))
                edges.append(LinkEdge(
                    id: "tether/\(device.id)/\(contact.id.uuidString)", source: impNodeID(contact.id, in: device.id), target: home,
                    sourceHandle: Port.tether(side), targetHandle: Port.tether(opposite(side)),
                    type: .bezier, zIndex: 1, deletable: false, interactionWidth: Metrics.interactionWidth,
                    data: EdgeData(kind: .tether(contact.id, in: device.id), look: .tether(hue: contact.hue), dimmed: false,
                                   live: device.shownState == .connected, ends: [device.id, home],
                                   label: words("devices.tether.label", contact.name, map.title(of: device.id), map.title(of: home)))))
            }
        }

        for device in shown {
            guard let place = places[device.id], let size = boxes[device.id] else { continue }
            let isHop = device.kind == .server
            nodes.append(FlowNode(
                id: device.id, position: XYPosition(x: place.x, y: place.y),
                data: NodeData(role: .device(device), hop: isHop ? standing : nil,
                               label: map.summary(of: device, standing: isHop ? standing : nil)), type: "group",
                width: size.width, height: size.height, draggable: true, selectable: false, connectable: false, deletable: false,
                sourcePosition: .right, targetPosition: .left))
            let residents = map.residents(of: device.id)
            let slots = chipFrames(count: residents.count, in: size.width, longestName: residents.map(\.name.count).max() ?? 0)
            for (index, contact) in residents.enumerated() {
                let ours = map.imp(contact.id) != nil
                let side = contact.home.flatMap { $0 != device.id && boxes[$0] != nil ? tetherSide(from: frame(device.id), home: frame($0)) : nil }
                nodes.append(FlowNode(
                    id: impNodeID(contact.id, in: device.id),
                    position: XYPosition(x: slots[index].minX, y: slots[index].minY),
                    data: NodeData(role: .imp(contact, ours: ours), hop: nil, away: contact.home != contact.location,
                                   label: words(ours ? "devices.chip.label_ours" : "devices.chip.label_visitor", contact.name, map.title(of: device.id))),
                    parentId: device.id, width: slots[index].width, height: slots[index].height,
                    draggable: false, selectable: false, connectable: false, deletable: false,
                    sourcePosition: side ?? .bottom))
            }
        }

        func plugs(of far: String) -> (symbols: [String], locked: Bool) {
            let trusted = map.node(far)?.isTrusted == true
            if let known = access[far] { return (known.pluggedIn.map(\.symbol), !known.trusted) }
            return (trusted ? [DeviceAccess.talkSymbol] : [], !trusted)
        }

        var throughHop: Set<String> = []
        for channel in links {
            let connected = channel.state == .connected
            let label = words("devices.edge.label", map.title(of: channel.from), map.title(of: channel.to), map.route(of: channel), channel.state.word)
            let far = channel.from == DeviceMap.thisMacID ? channel.to : channel.from
            let route: EdgeData.Route = channel.path == .relay ? .hop : .local
            let (symbols, locked) = plugs(of: far)
            if let via = channel.via, map.node(via) != nil, boxes[via] != nil {
                if throughHop.insert(via).inserted {
                    let (out, into) = (facing(from: frame(channel.from), to: frame(via)), facing(from: frame(via), to: frame(channel.from)))
                    edges.append(LinkEdge(
                        id: "hop/\(via)", source: channel.from, target: via,
                        sourceHandle: Port.line(out, .source), targetHandle: Port.line(into, .target), type: .bezier,
                        deletable: false, interactionWidth: Metrics.interactionWidth,
                        data: EdgeData(kind: .toHop(via), look: .hop, dimmed: !connected, live: connected, route: .hop,
                                       ends: [channel.from, via], label: words("devices.hop.edge.label", map.title(of: via), map.tag(of: channel)))))
                } else if connected, let index = edges.firstIndex(where: { $0.id == "hop/\(via)" }) {
                    edges[index].data?.dimmed = false
                    edges[index].data?.live = true
                }
                let (out, into) = (facing(from: frame(via), to: frame(channel.to)), facing(from: frame(channel.to), to: frame(via)))
                edges.append(LinkEdge(
                    id: "channel/\(channel.id)", source: via, target: channel.to,
                    sourceHandle: Port.line(out, .source), targetHandle: Port.line(into, .target), type: .bezier,
                    deletable: false, interactionWidth: Metrics.interactionWidth,
                    data: EdgeData(kind: .channel(channel.id), look: .hop, dimmed: !connected, live: connected, route: route,
                                   access: symbols, locked: locked, ends: [channel.from, channel.to], via: via, label: label)))
            } else {
                let (out, into) = (facing(from: frame(channel.from), to: frame(channel.to)), facing(from: frame(channel.to), to: frame(channel.from)))
                edges.append(LinkEdge(
                    id: "channel/\(channel.id)", source: channel.from, target: channel.to,
                    sourceHandle: Port.line(out, .source), targetHandle: Port.line(into, .target), type: .bezier,
                    deletable: false, interactionWidth: Metrics.interactionWidth,
                    data: EdgeData(kind: .channel(channel.id), look: route == .hop ? .hop : .local, dimmed: !connected, live: connected, route: route,
                                   access: symbols, locked: locked, ends: [channel.from, channel.to], label: label)))
            }
        }

        // Talk edges, from an Imp's chip to each chip of another device it can message. Hidden unless it is in focus.
        for entry in map.imps {
            for contact in entry.talksTo where contact.location != entry.location && boxes[contact.location] != nil
                && boxes[entry.location] != nil && hasChip(contact.id, on: contact.location) && hasChip(entry.id, on: entry.location) {
                let from = frame(entry.location), to = frame(contact.location)
                let out = facing(from: from, to: to), into = facing(from: to, to: from)
                edges.append(LinkEdge(
                    id: "talk/\(entry.id.uuidString)/\(contact.id.uuidString)",
                    source: impNodeID(entry.id, in: entry.location), target: impNodeID(contact.id, in: contact.location),
                    sourceHandle: Port.talk(out, .source), targetHandle: Port.talk(into, .target), type: .bezier,
                    hidden: true, zIndex: 2, deletable: false, focusable: false, interactionWidth: Metrics.interactionWidth,
                    data: EdgeData(kind: .talk(entry.id, contact.id), look: .talk(hue: entry.hue), dimmed: false, live: false,
                                   ends: [entry.location, contact.location],
                                   label: words("devices.talk.label", entry.name, contact.name))))
            }
        }
        return Graph(nodes: nodes, edges: edges)
    }

    // MARK: Handles

    /// The points where lines attach. A channel runs between the sides of devices that face each other, so every
    /// side is a point for both ends. A tether leaves the side of its Imp's chip that faces its home and arrives at the
    /// facing side of the home, so it runs clear of the channels and never under a card. A talk line leaves the side of a chip that faces its device.
    enum Port {
        static let sides: [Position] = [.left, .right, .top, .bottom]
        static func line(_ side: Position, _ type: HandleType) -> String { "line-\(name(type))-\(side.rawValue)" }
        static func talk(_ side: Position, _ type: HandleType) -> String { "talk-\(name(type))-\(side.rawValue)" }
        static func tether(_ side: Position) -> String { "tether-\(side.rawValue)" }
        static let tetherSides: [Position] = sides
        private static func name(_ type: HandleType) -> String { type == .source ? "source" : "target" }
    }

    /// The side of `a` that faces `b`: left or right when `b` is clear of it to a side, else top or bottom.
    static func facing(from a: CGRect, to b: CGRect) -> Position {
        if b.minX >= a.maxX { return .right }
        if b.maxX <= a.minX { return .left }
        return b.midY < a.midY ? .top : .bottom
    }

    /// Which side of the chip a tether leaves by: the one facing its home, so it runs straight across the gap to the
    /// home's facing side and never loops under the cards.
    static func tetherSide(from device: CGRect, home: CGRect) -> Position { facing(from: device, to: home) }

    /// The side across from `side`.
    static func opposite(_ side: Position) -> Position {
        switch side {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    // MARK: Geometry

    private static func gaps(_ count: Int) -> CGFloat { CGFloat(max(0, count - 1)) * Metrics.rowGap }

    /// The narrowest a chip may be: the least, or what the longest name among its device's Imps needs, so no name is cut.
    static func chipWidth(_ longestName: Int) -> CGFloat {
        max(Metrics.chipMinimum, Metrics.chipChrome + CGFloat(longestName) * Metrics.chipCharacter)
    }

    /// How many chips are in each row of a device `width` wide: as few rows as the width allows, balanced (four
    /// that need two rows go two and two), at most `maxChipColumns` across.
    static func chipRows(_ count: Int, in width: CGFloat, longestName: Int = 0) -> [Int] {
        let fit = Int((width - 2 * Metrics.padding + Metrics.chipGap) / (chipWidth(longestName) + Metrics.chipGap))
        return RowBalance.lineLengths(count: count, fit: max(1, min(Metrics.maxChipColumns, fit)))
    }

    /// Where the chips of a device `width` wide are inside it, in order: every row spans the full inner width, the
    /// same inset from the edges as the header's, and its chips share it equally. The first row starts under the header.
    static func chipFrames(count: Int, in width: CGFloat, longestName: Int = 0) -> [CGRect] {
        let inner = width - 2 * Metrics.padding
        var frames: [CGRect] = []
        for (row, length) in chipRows(count, in: width, longestName: longestName).enumerated() {
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
    /// no wider than `maximumWidth`. A single Imp fills the width of its device.
    static func box(of node: DeviceMap.Node, residents count: Int, longestName: Int = 0) -> CGSize {
        let across = CGFloat(min(Metrics.maxChipColumns, count))
        let imps = count > 0 ? 2 * Metrics.padding + across * chipWidth(longestName) + (across - 1) * Metrics.chipGap : 0
        let name = Metrics.headerChrome + CGFloat(node.title.count) * Metrics.titleCharacter
        let width = min(Metrics.maximumWidth, max(Metrics.minimumWidth, name, imps))
        guard count > 0 else { return CGSize(width: width, height: Metrics.header) }
        let rows = CGFloat(chipRows(count, in: width, longestName: longestName).count)
        return CGSize(width: width, height: Metrics.header + rows * Metrics.chipHeight + (rows - 1) * Metrics.chipGap + Metrics.padding)
    }
}

extension DeviceGraph.EdgeData {
    var isTether: Bool { if case .tether = kind { true } else { false } }
    var isTalk: Bool { if case .talk = kind { true } else { false } }
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

    /// What a click on an edge opens: a channel, the Hop for the half that is shared, or the Imp a tether or a talk
    /// line belongs to.
    func sheet(ofEdge id: String) -> DevicesSheet? {
        guard let edge = edges.first(where: { $0.id == id }), let kind = edge.data?.kind else { return nil }
        switch kind {
        case .channel(let id): return .opening(.channel(id))
        case .toHop(let hop): return .opening(.node(hop))
        case .tether, .talk: return sheet(ofNode: edge.source)
        }
    }

    /// This graph with the talk lines of Imp `imp` shown, as when it is in focus. Positions and ids stay as they are.
    func revealing(talkOf imp: UUID) -> DeviceGraph.Graph {
        var graph = self
        for index in graph.edges.indices {
            if case .talk(let id, _)? = graph.edges[index].data?.kind, id == imp { graph.edges[index].hidden = false }
        }
        return graph
    }

    /// This graph as drawn in `focus`: an Imp's talk lines are shown.
    func shown(in focus: DeviceGraph.Focus?) -> DeviceGraph.Graph {
        if case .imp(let imp, _)? = focus { return revealing(talkOf: imp) }
        return self
    }

    /// What hovering a node puts in focus.
    func focus(ofNode id: String) -> DeviceGraph.Focus? {
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        switch node.data.role {
        case .device(let device): return .device(device.id)
        case .imp(let contact, _): return node.parentId.map { .imp(contact.id, in: $0) }
        }
    }

    /// What hovering a line puts in focus: its channel, the Hop for the shared half, the Imp of a tether or talk line.
    func focus(ofEdge id: String) -> DeviceGraph.Focus? {
        guard let edge = edges.first(where: { $0.id == id }), let kind = edge.data?.kind else { return nil }
        switch kind {
        case .channel(let id): return .channel(id)
        case .toHop(let hop): return .device(hop)
        case .tether, .talk: return focus(ofNode: edge.source)
        }
    }

    /// The ids of the nodes and lines that stay bright in `focus`. The canvas draws the rest dimmed. An Imp lights its
    /// chips, the device its body is on and its home, the channels (and the Hop) between them, its tether and its talk
    /// lines with the Imps they reach. A device lights itself, its Imps, its channels (and the Hop) and the tethers
    /// in and out. A channel lights both ends, the Hop when it goes through it, and the Imps travelling over it with
    /// their tethers.
    func lit(for focus: DeviceGraph.Focus) -> Set<String> {
        var ids: Set<String> = []
        func chips(where match: (DeviceMap.Contact, String?) -> Bool) -> [DeviceGraph.FlowNode] {
            nodes.filter { if case .imp(let contact, _) = $0.data.role { match(contact, $0.parentId) } else { false } }
        }
        func light(_ edge: DeviceGraph.LinkEdge) {
            ids.insert(edge.id)
            if let via = edge.data?.via {
                ids.insert(via)
                if edges.contains(where: { $0.id == "hop/\(via)" }) { ids.insert("hop/\(via)") }
            }
            if case .toHop(let hop)? = edge.data?.kind { ids.insert(hop) }
        }
        switch focus {
        case .imp(let imp, _):
            let mine = chips { contact, _ in contact.id == imp }
            let bodies = Set(mine.compactMap(\.parentId))
            ids.formUnion(mine.map(\.id))
            ids.formUnion(bodies)
            var homes: Set<String> = []
            for edge in edges {
                switch edge.data?.kind {
                case .tether(let id, _) where id == imp: light(edge); homes.insert(edge.target)
                case .talk(let id, _) where id == imp:
                    light(edge); ids.insert(edge.target)
                    if let parent = nodes.first(where: { $0.id == edge.target })?.parentId { ids.insert(parent) }
                default: break
                }
            }
            ids.formUnion(homes)
            for edge in edges {
                guard case .channel? = edge.data?.kind, let ends = edge.data?.ends, ends.count == 2 else { continue }
                if bodies.contains(where: { body in homes.contains { home in body != home && Set(ends) == [body, home] } }) { light(edge) }
            }
        case .device(let device):
            ids.insert(device)
            ids.formUnion(nodes.filter { $0.parentId == device }.map(\.id))
            for edge in edges where !(edge.data?.isTalk ?? true) && (edge.data?.ends.contains(device) == true || edge.source == device || edge.target == device) {
                light(edge)
                if edge.data?.isTether == true { ids.insert(edge.source) }
            }
        case .channel(let channel):
            let channelEdges = edges.filter { if case .channel(let id)? = $0.data?.kind { id == channel } else { false } }
            channelEdges.forEach(light)
            let ends = Set(channelEdges.flatMap { $0.data?.ends ?? [] })
            ids.formUnion(ends)
            for chip in chips(where: { contact, parent in
                parent.map { ends.contains($0) } == true && contact.home.map { ends.contains($0) } == true && contact.home != parent
            }) {
                ids.insert(chip.id)
                for edge in edges where edge.source == chip.id && edge.data?.isTether == true { light(edge) }
            }
        }
        return ids
    }

    /// Everything that can be opened, in reading order, for a screen reader and the keyboard. Talk lines are not
    /// lines of their own: they belong to their Imp.
    var openable: [Openable] {
        let devices = nodes.filter { $0.parentId == nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let imps = nodes.filter { $0.parentId != nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let lines = edges.filter { $0.data?.isTalk == false }.compactMap { edge in
            edge.data.flatMap { data in sheet(ofEdge: edge.id).map { Openable(label: data.label, sheet: $0) } }
        }
        return devices + imps + lines
    }
}
