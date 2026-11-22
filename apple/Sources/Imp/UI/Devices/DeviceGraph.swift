import CoreGraphics
import ImpDesign
import ImpKit
import SwiftFlow
import SwiftUI

/// The Devices screen as a graph for the canvas: a pure mapping from what `DeviceMap` knows to SwiftFlow's nodes
/// and edges, with their first places. The canvas only draws it, so the shape of the graph is tested.
///
/// A device (This Mac, a linked device, a device known only through another) is a group node. An Imp whose body is
/// on a device is a child node inside it, in a grid. A channel is ONE edge between two devices, solid on the local
/// network and dashed through the Hop. The Hop is not a node (it is a button in the screen's bar). A device known
/// only through another is joined to the device that relays it by a thin dotted edge. An Imp that is away from its
/// home has a tether to the home device, and an Imp that can talk to Imps on other devices has a talk edge to each:
/// both are hidden until the Imp or its device is in focus. A talk line is drawn above the devices from chip to chip (`talkRoutes`),
/// the canvas draws it itself. This Mac is in the middle and the other devices are on
/// its two sides (each next to the shorter side, so the picture stays balanced). Where a device was dragged to is
/// remembered by the caller and passed in as `moved`, so a refresh of the link never puts it back.
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
        /// The least room between two ports on the same side of a device, and how far from a corner the first may be.
        static let dockGap: CGFloat = 12
        static let dockInset: CGFloat = 10
        /// How far down a device's side its channel attaches: level with the middle of its header, above every dock.
        static let channelPort: CGFloat = header / 2
    }

    struct NodeData: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            case device(DeviceMap.Node)
            case imp(DeviceMap.Contact, ours: Bool)
        }

        var role: Role
        /// An Imp whose body is not where it thinks (not on its home device): it gets a small mark.
        var away = false
        /// For an Imp that is away: the symbol of its home device, shown on its chip so where it lives is seen without lines.
        var homeSymbol: String?
        /// For a device: the ports of the Imps' tethers on its sides, each in its Imp's colour.
        var docks: [Dock] = []
        /// What a screen reader says about it.
        var label: String
    }

    /// The port of one Imp's tether on the side of a device: where the line leaves the device its body is on, or arrives
    /// at its home. Each Imp has its own, so a line starts and ends at a point that is the Imp's alone.
    struct Dock: Equatable, Sendable {
        var id: String
        var type: HandleType
        var side: Position
        /// How far along the side it is: from the top on a left or right side, from the left on a top or bottom side.
        var offset: CGFloat
    }

    /// An Imp whose body is on one device and whose home is another, with where its chip is (on the canvas).
    struct Tether: Equatable {
        var imp: UUID
        var body: String
        var home: String
        var chip: CGRect
    }

    struct EdgeData: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// A channel between two devices (`DeviceMap.Channel.id`).
            case channel(String)
            /// A device known only through another (its node id), joined to the linked device that relays it.
            case relay(String)
            /// An Imp in a device that isn't its home, tied to its home. Hidden until it is in focus.
            case tether(UUID, in: String)
            /// An Imp (first) that can message another device's Imp (second). Hidden until the first is in focus.
            case talk(UUID, UUID)
        }

        enum Look: Hashable, Sendable {
            /// Solid: the local network.
            case local
            /// Dashed: through the Hop.
            case hop
            /// Thin and dotted: known through another device.
            case relay
            case tether(hue: Double)
            case talk(hue: Double)
        }

        var kind: Kind
        var look: Look
        /// Not connected right now: drawn faint.
        var dimmed: Bool
        /// Something flows on it right now: a connected channel, a tether to a device that is there.
        var live = false
        /// The devices this line is between (a tether: where the Imp is and its home).
        var ends: [String] = []
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

        /// The focus of an open sheet. The Link sheet and the Hop's are about no one device.
        init?(_ sheet: DevicesSheet) {
            switch sheet {
            case .about(let selection): self.init(selection)
            case .hop, .link: return nil
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

    /// Talk edges and tethers are all there but hidden. `shown(in:)` shows the ones in focus.
    static func build(_ map: DeviceMap, moved: [String: CGPoint] = [:]) -> Graph {
        let shown = map.nodes.filter { $0.kind != .server }
        let links = map.channels.filter { map.node($0.from) != nil && map.node($0.to) != nil }

        // Sizes, then columns: This Mac in the middle, the other devices on both sides.
        var boxes: [String: CGSize] = [:]
        var arriving: [String: Int] = [:]
        for node in shown {
            for contact in map.residents(of: node.id) {
                if let home = contact.home, home != node.id { arriving[home, default: 0] += 1 }
            }
        }
        for node in shown { boxes[node.id] = box(of: node, residents: map.residents(of: node.id).count,
                                       longestName: map.residents(of: node.id).map(\.name.count).max() ?? 0, arriving: arriving[node.id] ?? 0) }
        func height(_ node: DeviceMap.Node) -> CGFloat { boxes[node.id]?.height ?? 0 }
        func width(_ node: DeviceMap.Node) -> CGFloat { boxes[node.id]?.width ?? 0 }
        let thisMac = shown.first { $0.kind == .thisMac }
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
        let middleWidth = thisMac.map(width) ?? 0
        let middleX = leading.isEmpty ? 0 : leadingWidth + Metrics.columnGap
        let trailingX = middleX + middleWidth + Metrics.columnGap

        var places: [String: CGPoint] = [:]
        let macHeight = thisMac.map(height) ?? 0
        if let thisMac { places[thisMac.id] = CGPoint(x: middleX + (middleWidth - width(thisMac)) / 2, y: 0) }
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

        var slots: [String: [CGRect]] = [:]
        for device in shown {
            let residents = map.residents(of: device.id)
            slots[device.id] = chipFrames(count: residents.count, in: boxes[device.id]?.width ?? 0, longestName: residents.map(\.name.count).max() ?? 0)
        }
        // An Imp away from its home is tied to it: the line leaves its device and arrives at its home by ports of its own.
        var tethered: [(tether: Tether, contact: DeviceMap.Contact)] = []
        for device in shown {
            for (index, contact) in map.residents(of: device.id).enumerated() {
                guard let home = contact.home, home != device.id, map.node(home) != nil, boxes[home] != nil, let slot = slots[device.id]?[index] else { continue }
                let origin = frame(device.id).origin
                tethered.append((Tether(imp: contact.id, body: device.id, home: home, chip: slot.offsetBy(dx: origin.x, dy: origin.y)), contact))
            }
        }
        let docks = docks(for: tethered.map(\.tether), frames: Dictionary(uniqueKeysWithValues: shown.map { ($0.id, frame($0.id)) }))

        var nodes: [FlowNode] = []
        var edges: [LinkEdge] = []
        for (tether, contact) in tethered {
            let body = map.node(tether.body)
            edges.append(LinkEdge(
                id: "tether/\(tether.body)/\(contact.id.uuidString)", source: impNodeID(contact.id, in: tether.body), target: tether.home,
                sourceHandle: Port.dock(.source, imp: tether.imp, body: tether.body), targetHandle: Port.dock(.target, imp: tether.imp, body: tether.body),
                type: .bezier, hidden: true, zIndex: 1, deletable: false, interactionWidth: Metrics.interactionWidth,
                data: EdgeData(kind: .tether(contact.id, in: tether.body), look: .tether(hue: contact.hue), dimmed: false,
                               live: body?.shownState == .connected, ends: [tether.body, tether.home],
                               label: words("devices.tether.label", contact.name, map.title(of: tether.body), map.title(of: tether.home)))))
        }

        for device in shown {
            guard let place = places[device.id], let size = boxes[device.id] else { continue }
            nodes.append(FlowNode(
                id: device.id, position: XYPosition(x: place.x, y: place.y),
                data: NodeData(role: .device(device), docks: docks[device.id] ?? [], label: map.summary(of: device)), type: "group",
                width: size.width, height: size.height, draggable: true, selectable: false, connectable: false, deletable: false,
                sourcePosition: .right, targetPosition: .left))
            for (index, contact) in map.residents(of: device.id).enumerated() {
                let ours = map.imp(contact.id) != nil
                let slot = slots[device.id]?[index] ?? .zero
                nodes.append(FlowNode(
                    id: impNodeID(contact.id, in: device.id),
                    position: XYPosition(x: slot.minX, y: slot.minY),
                    data: NodeData(role: .imp(contact, ours: ours), away: contact.home != contact.location,
                                   homeSymbol: contact.home != contact.location ? (contact.home.flatMap { map.node($0)?.symbol } ?? "house") : nil,
                                   label: words(ours ? "devices.chip.label_ours" : "devices.chip.label_visitor", contact.name, map.title(of: device.id))),
                    parentId: device.id, width: slot.width, height: slot.height,
                    draggable: false, selectable: false, connectable: false, deletable: false))
            }
        }

        // A channel is one line, whatever its route: dashed through the Hop.
        for channel in links {
            let connected = channel.state == .connected
            let (out, into) = (facing(from: frame(channel.from), to: frame(channel.to)), facing(from: frame(channel.to), to: frame(channel.from)))
            edges.append(LinkEdge(
                id: "channel/\(channel.id)", source: channel.from, target: channel.to,
                sourceHandle: Port.line(out, .source), targetHandle: Port.line(into, .target), type: .bezier,
                deletable: false, interactionWidth: Metrics.interactionWidth,
                data: EdgeData(kind: .channel(channel.id), look: channel.path == .relay ? .hop : .local, dimmed: !connected, live: connected,
                               ends: [channel.from, channel.to],
                               label: words("devices.edge.label", map.title(of: channel.from), map.title(of: channel.to), map.route(of: channel), channel.state.word))))
        }
        // A device known only through another hangs on it by a thin dotted line.
        for node in shown where !node.linked {
            guard let via = node.via, via != node.id, boxes[via] != nil, boxes[node.id] != nil else { continue }
            let (out, into) = (facing(from: frame(via), to: frame(node.id)), facing(from: frame(node.id), to: frame(via)))
            edges.append(LinkEdge(
                id: "relay/\(node.id)", source: via, target: node.id,
                sourceHandle: Port.line(out, .source), targetHandle: Port.line(into, .target), type: .bezier,
                deletable: false, interactionWidth: Metrics.interactionWidth,
                data: EdgeData(kind: .relay(node.id), look: .relay, dimmed: false, ends: [via, node.id],
                               label: words("devices.status.through", map.title(of: via)))))
        }

        // Talk edges, from an Imp's chip to each chip of another device it can message. Hidden unless it is in focus.
        for entry in map.imps {
            for contact in entry.talksTo where contact.location != entry.location && boxes[contact.location] != nil
                && boxes[entry.location] != nil && hasChip(contact.id, on: contact.location) && hasChip(entry.id, on: entry.location) {
                edges.append(LinkEdge(
                    id: "talk/\(entry.id.uuidString)/\(contact.id.uuidString)",
                    source: impNodeID(entry.id, in: entry.location), target: impNodeID(contact.id, in: contact.location), type: .bezier,
                    hidden: true, zIndex: 2, deletable: false, focusable: false, interactionWidth: Metrics.interactionWidth,
                    data: EdgeData(kind: .talk(entry.id, contact.id), look: .talk(hue: entry.hue), dimmed: false, live: false,
                                   ends: [entry.location, contact.location],
                                   label: words("devices.talk.label", entry.name, contact.name))))
            }
        }
        return Graph(nodes: nodes, edges: edges)
    }

    // MARK: Handles

    /// The points where lines attach. A channel runs between the sides of devices that face each other, level with the
    /// header, so every side is a point for both ends. A tether leaves the side of its device that faces its home and
    /// arrives at the facing side of the home, each end at a dock of its own Imp. A talk line has no handles: it is drawn
    /// above the devices, from chip to chip (`talkRoutes`).
    enum Port {
        static let sides: [Position] = [.left, .right, .top, .bottom]
        static func line(_ side: Position, _ type: HandleType) -> String { "line-\(name(type))-\(side.rawValue)" }
        /// The dock of `imp`'s tether on the device `body` it is on: it leaves there and arrives at its home's.
        static func dock(_ type: HandleType, imp: UUID, body: String) -> String { "dock-\(name(type))-\(body)-\(imp.uuidString)" }
        private static func name(_ type: HandleType) -> String { type == .source ? "source" : "target" }
    }

    /// The side of `a` that faces `b`: left or right when `b` is clear of it to a side, else top or bottom.
    static func facing(from a: CGRect, to b: CGRect) -> Position {
        if b.minX >= a.maxX { return .right }
        if b.maxX <= a.minX { return .left }
        return b.midY < a.midY ? .top : .bottom
    }

    /// The side across from `side`.
    static func opposite(_ side: Position) -> Position {
        switch side {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    // MARK: Talk lines

    /// A talk line as it is drawn: from a port on one chip to a port on another, in canvas units.
    struct Route: Equatable {
        var edge: String
        var data: EdgeData
        var from: CGPoint
        var fromSide: Position
        var to: CGPoint
        var toSide: Position
    }

    /// The side of the chip `frame` that a line to `other` uses: the one that faces it, unless another chip of its
    /// device (`among`) is in the way there, then the top or the bottom, whichever has no chip next to it.
    static func openSide(of frame: CGRect, toward other: CGRect, among siblings: [CGRect]) -> Position {
        let side = facing(from: frame, to: other)
        guard side == .left || side == .right else { return side }
        let row = siblings.filter { $0 != frame && $0.minY < frame.maxY && $0.maxY > frame.minY }
        let blocked = row.contains { side == .right ? $0.minX >= frame.maxX : $0.maxX <= frame.minX }
        guard blocked else { return side }
        return siblings.contains { $0.maxY <= frame.minY && $0.minX < frame.maxX && $0.maxX > frame.minX } ? .bottom : .top
    }

    /// The frames of every Imp's chip on the canvas, by node id.
    static func chipFrames(in graph: Graph) -> [String: CGRect] {
        let origins = Dictionary(uniqueKeysWithValues: graph.nodes.filter { $0.parentId == nil }.map { ($0.id, CGPoint(x: $0.position.x, y: $0.position.y)) })
        var frames: [String: CGRect] = [:]
        for node in graph.nodes {
            guard case .imp = node.data.role, let parent = node.parentId, let origin = origins[parent] else { continue }
            frames[node.id] = CGRect(x: origin.x + node.position.x, y: origin.y + node.position.y, width: node.width ?? 0, height: node.height ?? 0)
        }
        return frames
    }

    /// The talk lines that are shown, each from the side of its chip that faces the other chip to the side of the other
    /// that faces it. The canvas draws them above the devices, because a line under a card would be lost in it. A
    /// chip's lines on one side each have a port of their own, spread over the side in the order of the chips at
    /// their other ends, so they fan out the way the chips are and do not cross.
    static func talkRoutes(in graph: Graph) -> [Route] {
        let frames = chipFrames(in: graph)
        struct End: Hashable { var chip: String; var side: Position }
        struct Use { var edge: String; var source: Bool; var other: CGRect }
        let parents = Dictionary(uniqueKeysWithValues: graph.nodes.compactMap { node in node.parentId.map { (node.id, $0) } })
        func siblings(of chip: String) -> [CGRect] { frames.filter { parents[$0.key] == parents[chip] }.map(\.value) }
        var uses: [End: [Use]] = [:]
        let lines = graph.edges.filter { $0.data?.isTalk == true && !$0.hidden }
        for edge in lines {
            guard let a = frames[edge.source], let b = frames[edge.target] else { continue }
            uses[End(chip: edge.source, side: openSide(of: a, toward: b, among: siblings(of: edge.source))), default: []].append(Use(edge: edge.id, source: true, other: b))
            uses[End(chip: edge.target, side: openSide(of: b, toward: a, among: siblings(of: edge.target))), default: []].append(Use(edge: edge.id, source: false, other: a))
        }
        var points: [String: (from: (CGPoint, Position)?, to: (CGPoint, Position)?)] = [:]
        for (end, group) in uses {
            guard let frame = frames[end.chip] else { continue }
            let ordered = group.sorted { (along(CGPoint(x: $0.other.midX, y: $0.other.midY), end.side), $0.edge) < (along(CGPoint(x: $1.other.midX, y: $1.other.midY), end.side), $1.edge) }
            for (index, use) in ordered.enumerated() {
                let share = CGFloat(index + 1) / CGFloat(ordered.count + 1)
                let point: CGPoint
                switch end.side {
                case .left: point = CGPoint(x: frame.minX, y: frame.minY + frame.height * share)
                case .right: point = CGPoint(x: frame.maxX, y: frame.minY + frame.height * share)
                case .top: point = CGPoint(x: frame.minX + frame.width * share, y: frame.minY)
                case .bottom: point = CGPoint(x: frame.minX + frame.width * share, y: frame.maxY)
                }
                if use.source { points[use.edge, default: (nil, nil)].from = (point, end.side) } else { points[use.edge, default: (nil, nil)].to = (point, end.side) }
            }
        }
        return lines.compactMap { edge in
            guard let data = edge.data, let from = points[edge.id]?.from, let to = points[edge.id]?.to else { return nil }
            return Route(edge: edge.id, data: data, from: from.0, fromSide: from.1, to: to.0, toSide: to.1)
        }
    }

    // MARK: Docks

    /// Where each Imp's tether leaves and arrives, by device. Every tether has one dock on the side of its device that
    /// faces its home and one on the facing side of its home, in order of where its chip is, so the lines run side by
    /// side and never cross. Docks on one side keep apart (`spread`).
    static func docks(for tethers: [Tether], frames: [String: CGRect]) -> [String: [Dock]] {
        // Top to bottom, then left to right: the one order both ends share.
        let ordered = tethers.sorted {
            ($0.chip.midY, $0.chip.midX, $0.imp.uuidString, $0.body) < ($1.chip.midY, $1.chip.midX, $1.imp.uuidString, $1.body)
        }
        struct End: Hashable { var device: String; var side: Position }
        var groups: [End: [(tether: Tether, type: HandleType, wanted: CGFloat)]] = [:]
        for tether in ordered {
            guard let body = frames[tether.body], let home = frames[tether.home] else { continue }
            let side = facing(from: body, to: home)
            let point = CGPoint(x: tether.chip.midX, y: tether.chip.midY)
            groups[End(device: tether.body, side: side), default: []].append((tether, .source, along(point, side) - along(body.origin, side)))
            groups[End(device: tether.home, side: opposite(side)), default: []].append((tether, .target, along(point, side) - along(home.origin, side)))
        }
        var docks: [String: [Dock]] = [:]
        for (end, group) in groups {
            guard let frame = frames[end.device] else { continue }
            let offsets = spread(group.map(\.wanted), gap: Metrics.dockGap, in: dockRange(end.side, of: frame.size))
            for (entry, offset) in zip(group, offsets) {
                docks[end.device, default: []].append(Dock(id: Port.dock(entry.type, imp: entry.tether.imp, body: entry.tether.body),
                                                           type: entry.type, side: end.side, offset: offset))
            }
        }
        return docks.mapValues { $0.sorted { ($0.side.rawValue, $0.offset, $0.id) < ($1.side.rawValue, $1.offset, $1.id) } }
    }

    /// The coordinate of `point` along `side`: down it on a left or right side, across it on a top or bottom one.
    private static func along(_ point: CGPoint, _ side: Position) -> CGFloat {
        side == .left || side == .right ? point.y : point.x
    }

    /// Where on `side` of a device of `size` a dock may be: clear of the corners, and on a left or right side below
    /// the channel's port.
    static func dockRange(_ side: Position, of size: CGSize) -> ClosedRange<CGFloat> {
        let vertical = side == .left || side == .right
        let low = vertical ? Metrics.channelPort + Metrics.dockGap : Metrics.dockInset
        let high = (vertical ? size.height : size.width) - Metrics.dockInset
        return low...max(low, high)
    }

    /// Places that are as near as they can be to what is `wanted`, in `range` and at least `gap` apart, in the order
    /// of what is wanted. When they cannot all keep `gap` they share the room evenly. The result is in the order of `wanted`.
    static func spread(_ wanted: [CGFloat], gap: CGFloat, in range: ClosedRange<CGFloat>) -> [CGFloat] {
        guard !wanted.isEmpty else { return [] }
        let order = wanted.indices.sorted { (wanted[$0], $0) < (wanted[$1], $1) }
        let step = order.count > 1 ? min(gap, (range.upperBound - range.lowerBound) / CGFloat(order.count - 1)) : 0
        var placed: [CGFloat] = []
        var previous = -CGFloat.infinity
        for index in order {
            previous = max(min(max(wanted[index], range.lowerBound), range.upperBound), previous + step)
            placed.append(previous)
        }
        // What was pushed past the end comes back, the ones before it with it.
        var next = range.upperBound
        for slot in placed.indices.reversed() {
            placed[slot] = min(placed[slot], next)
            next = placed[slot] - step
        }
        var result = [CGFloat](repeating: 0, count: wanted.count)
        for (slot, index) in order.enumerated() { result[index] = placed[slot] }
        return result
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
    /// no wider than `maximumWidth`. A single Imp fills the width of its device. It is tall enough for the docks of the
    /// `arriving` tethers of Imps that are away from it.
    static func box(of node: DeviceMap.Node, residents count: Int, longestName: Int = 0, arriving: Int = 0) -> CGSize {
        let across = CGFloat(min(Metrics.maxChipColumns, count))
        let imps = count > 0 ? 2 * Metrics.padding + across * chipWidth(longestName) + (across - 1) * Metrics.chipGap : 0
        let name = Metrics.headerChrome + CGFloat(node.title.count) * Metrics.titleCharacter
        let width = min(Metrics.maximumWidth, max(Metrics.minimumWidth, name, imps))
        let docks = Metrics.channelPort + Metrics.dockGap + CGFloat(max(0, arriving - 1)) * Metrics.dockGap + Metrics.dockInset
        guard count > 0 else { return CGSize(width: width, height: max(Metrics.header, docks)) }
        let rows = CGFloat(chipRows(count, in: width, longestName: longestName).count)
        return CGSize(width: width, height: max(docks, Metrics.header + rows * Metrics.chipHeight + (rows - 1) * Metrics.chipGap + Metrics.padding))
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

    /// What a click on an edge opens: a channel, the device a dotted line leads to, or the Imp a tether or a talk
    /// line belongs to.
    func sheet(ofEdge id: String) -> DevicesSheet? {
        guard let edge = edges.first(where: { $0.id == id }), let kind = edge.data?.kind else { return nil }
        switch kind {
        case .channel(let id): return .opening(.channel(id))
        case .relay(let node): return .opening(.node(node))
        case .tether, .talk: return sheet(ofNode: edge.source)
        }
    }

    /// This graph with the lines of Imp `imp` shown, as when it is in focus: its tether and its talk lines. Positions
    /// and ids stay as they are.
    func revealing(imp: UUID) -> DeviceGraph.Graph {
        var graph = self
        for index in graph.edges.indices {
            switch graph.edges[index].data?.kind {
            case .talk(let id, _)? where id == imp: graph.edges[index].hidden = false
            case .tether(let id, _)? where id == imp: graph.edges[index].hidden = false
            default: break
            }
        }
        return graph
    }

    /// This graph with the tethers in and out of `device` shown, as when it is in focus.
    func revealing(tethersOf device: String) -> DeviceGraph.Graph {
        var graph = self
        for index in graph.edges.indices where graph.edges[index].data?.isTether == true && graph.edges[index].data?.ends.contains(device) == true {
            graph.edges[index].hidden = false
        }
        return graph
    }

    /// This graph as drawn in `focus`: an Imp shows its tether and talk lines, a device the tethers in and out of it.
    func shown(in focus: DeviceGraph.Focus?) -> DeviceGraph.Graph {
        switch focus {
        case .imp(let imp, _)?: return revealing(imp: imp)
        case .device(let device)?: return revealing(tethersOf: device)
        case .channel?, nil: return self
        }
    }

    /// What hovering a node puts in focus.
    func focus(ofNode id: String) -> DeviceGraph.Focus? {
        guard let node = nodes.first(where: { $0.id == id }) else { return nil }
        switch node.data.role {
        case .device(let device): return .device(device.id)
        case .imp(let contact, _): return node.parentId.map { .imp(contact.id, in: $0) }
        }
    }

    /// What hovering a line puts in focus: its channel, the device of a dotted line, the Imp of a tether or talk line.
    func focus(ofEdge id: String) -> DeviceGraph.Focus? {
        guard let edge = edges.first(where: { $0.id == id }), let kind = edge.data?.kind else { return nil }
        switch kind {
        case .channel(let id): return .channel(id)
        case .relay(let node): return .device(node)
        case .tether, .talk: return focus(ofNode: edge.source)
        }
    }

    /// The ids of the nodes and lines that stay bright in `focus`. The canvas draws the rest dimmed. An Imp lights its
    /// chips, the device its body is on and its home, the channels between them, its tether and its talk
    /// lines with the Imps they reach. A device lights itself, its Imps, its channels and dotted lines with the devices at their other ends, and the
    /// tethers in and out. A channel lights both ends and the Imps travelling over it with their tethers.
    func lit(for focus: DeviceGraph.Focus) -> Set<String> {
        var ids: Set<String> = []
        func chips(where match: (DeviceMap.Contact, String?) -> Bool) -> [DeviceGraph.FlowNode] {
            nodes.filter { if case .imp(let contact, _) = $0.data.role { match(contact, $0.parentId) } else { false } }
        }
        func light(_ edge: DeviceGraph.LinkEdge) {
            ids.insert(edge.id)
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
                ids.formUnion(edge.data?.ends ?? [])
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

    /// Everything that can be opened, in reading order, for a screen reader and the keyboard. Tethers and talk lines are
    /// not lines of their own: they belong to their Imp.
    var openable: [Openable] {
        let devices = nodes.filter { $0.parentId == nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let imps = nodes.filter { $0.parentId != nil }.compactMap { node in sheet(ofNode: node.id).map { Openable(label: node.data.label, sheet: $0) } }
        let lines = edges.filter { $0.data?.isTalk == false && $0.data?.isTether == false }.compactMap { edge in
            edge.data.flatMap { data in sheet(ofEdge: edge.id).map { Openable(label: data.label, sheet: $0) } }
        }
        return devices + imps + lines
    }
}
