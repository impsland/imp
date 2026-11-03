import ImpDesign
import ImpKit
import SwiftUI

/// The Devices tab: a map of the system (devices, the channels between them and the server they go
/// through), what each Imp can do and who it can talk to, and the actions that link devices.
struct DevicesPane: View {
    let model: AppModel

    var map: DeviceMap { DevicesPane.map(for: model) }

    /// The map for the current link state, preferences and troupe.
    static func map(for model: AppModel) -> DeviceMap {
        let peers = model.link.peers.map { peer in
            DeviceMap.Peer(id: peer.id, name: peer.name, kind: peer.kind,
                           reach: { switch peer.reach { case .direct: .direct; case .viaServer: .viaServer; case .away: .away } }(),
                           isTrusted: peer.isTrusted)
        }
        return DeviceMap.build(thisMac: DeviceLink.deviceName, peers: peers, server: model.prefs.server,
                               imps: model.prefs.imps, mcpServers: model.prefs.mcpServers)
    }

    var body: some View {
        let map = map
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Card("Map", icon: "point.3.connected.trianglepath.dotted",
                 info: "Your devices and how they talk. A solid line is connected, a dashed one is not. A line through a server shows its name.") {
                DeviceMapView(map: map, imps: model.prefs.imps)
                MapLegend()
            }
            ImpsCard(map: map)
            DevicesCard(model: model)
        }
    }
}

// MARK: Words

extension DeviceMap.State {
    var title: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting")
        case .offline: String(localized: "Offline")
        }
    }

    var color: Color {
        switch self {
        case .connected: Dungeon.good
        case .connecting: Dungeon.ember
        case .offline: Dungeon.muted
        }
    }
}

extension DeviceMap.Channel {
    /// How the channel runs: "On the local network" or "Through imp.example.org".
    var route: String {
        server.map { String(localized: "Through \($0)") } ?? String(localized: "On the local network")
    }
}

extension DeviceMap.Node {
    var symbol: String {
        switch kind {
        case .thisMac, .mac: "desktopcomputer"
        case .phone: "iphone.gen3"
        case .server: "server.rack"
        }
    }

    var title: String {
        kind == .thisMac ? String(localized: "\(name) (this Mac)") : name
    }
}

// MARK: The picture

private struct DeviceMapView: View {
    let map: DeviceMap
    let imps: [ImpProfile]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let nodeSize = CGSize(width: 150, height: 66)

    private var height: CGFloat {
        let devices = max(map.nodes.filter { $0.kind == .mac || $0.kind == .phone }.count, 1)
        return max(230, CGFloat(devices) * 92 + 60)
    }

    /// Where each node sits: this Mac on the left, the server in the middle, the other devices on the right.
    private func positions(in size: CGSize) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        let half = Self.nodeSize.width / 2 + 4
        result[DeviceMap.thisMacID] = CGPoint(x: half, y: size.height / 2)
        let devices = map.nodes.filter { $0.kind == .mac || $0.kind == .phone }
        let hasServer = map.node(DeviceMap.serverID) != nil
        for (i, node) in devices.enumerated() {
            let top = hasServer ? Self.nodeSize.height * 1.5 + 12 : Self.nodeSize.height / 2 + 4
            let bottom = size.height - Self.nodeSize.height / 2 - 4
            let y = devices.count == 1 ? (top + bottom) / 2 : top + (bottom - top) * CGFloat(i) / CGFloat(devices.count - 1)
            result[node.id] = CGPoint(x: size.width - half, y: y)
        }
        if hasServer { result[DeviceMap.serverID] = CGPoint(x: size.width / 2, y: Self.nodeSize.height / 2 + 2) }
        return result
    }

    /// The lines to draw: a direct channel is one, a relay channel is two (device to server to device).
    private struct Segment: Identifiable {
        var id: String
        var from: String
        var to: String
        var state: DeviceMap.State
        var label: String?
        var anchor: CGFloat
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var macToServer: DeviceMap.State?
        for channel in map.channels {
            if let via = channel.via {
                let best: DeviceMap.State = [macToServer, channel.state].compactMap { $0 }.contains(.connected) ? .connected : channel.state
                macToServer = best
                result.append(Segment(id: channel.id + ".out", from: via, to: channel.to, state: channel.state,
                                      label: channel.server, anchor: 0.5))
            } else {
                result.append(Segment(id: channel.id, from: channel.from, to: channel.to, state: channel.state,
                                      label: String(localized: "Local network"), anchor: 0.5))
            }
        }
        if let macToServer {
            result.append(Segment(id: "mac.server", from: DeviceMap.thisMacID, to: DeviceMap.serverID, state: macToServer, label: nil, anchor: 0.5))
        }
        // Offline lines first, so a connected line shared with them stays on top.
        return result.sorted { ($0.state == .connected ? 1 : 0) < ($1.state == .connected ? 1 : 0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let spots = positions(in: proxy.size)
            ZStack {
                edges(spots)
                ForEach(segments) { segment in
                    if let label = segment.label, let a = spots[segment.from], let b = spots[segment.to] {
                        pill(label, state: segment.state)
                            .position(x: a.x + (b.x - a.x) * segment.anchor, y: a.y + (b.y - a.y) * segment.anchor)
                    }
                }
                ForEach(map.nodes) { node in
                    if let spot = spots[node.id] { nodeView(node).position(spot) }
                }
            }
        }
        .frame(height: height)
        .accessibilityRepresentation { structuredList }
    }

    @ViewBuilder
    private func edges(_ spots: [String: CGPoint]) -> some View {
        let lines = segments.compactMap { segment -> (DeviceMap.State, CGPoint, CGPoint)? in
            guard let a = spots[segment.from], let b = spots[segment.to] else { return nil }
            return (segment.state, a, b)
        }
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !lines.contains { $0.0 == .connected })) { context in
            let phase = reduceMotion ? 0 : -context.date.timeIntervalSinceReferenceDate * 14
            Canvas { canvas, _ in
                for (state, a, b) in lines {
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    switch state {
                    case .connected:
                        canvas.stroke(path, with: .color(state.color.opacity(0.85)),
                                      style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 7], dashPhase: phase))
                    case .connecting:
                        canvas.stroke(path, with: .color(state.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
                    case .offline:
                        canvas.stroke(path, with: .color(Color.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 6]))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func pill(_ text: String, state: DeviceMap.State) -> some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text(verbatim: text).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Dungeon.cream).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Dungeon.deep))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
        .accessibilityHidden(true)
    }

    private func nodeView(_ node: DeviceMap.Node) -> some View {
        let here = node.imps.compactMap { id in imps.first { $0.id == id } }
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: node.symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(node.kind == .thisMac ? Dungeon.flame : Dungeon.cream)
                Text(verbatim: node.name).font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Dungeon.cream).lineLimit(1)
            }
            if node.kind == .thisMac {
                Text("This Mac").font(.system(size: 10.5)).foregroundStyle(Dungeon.muted)
            } else if node.kind == .server {
                Text(node.state == .connected ? "Relaying" : "Not in use").font(.system(size: 10.5)).foregroundStyle(Dungeon.muted)
            } else {
                Text(verbatim: node.state.title).font(.system(size: 10.5)).foregroundStyle(node.state.color)
            }
            if !here.isEmpty {
                HStack(spacing: 3) {
                    ForEach(here.prefix(6)) { imp in
                        Circle().fill(Color.imp(imp.hue)).frame(width: 9, height: 9)
                    }
                    if here.count > 6 { Text(verbatim: "+\(here.count - 6)").font(.system(size: 9)).foregroundStyle(Dungeon.muted) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
        .background(RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous).fill(Dungeon.deep))
        .overlay(RoundedRectangle(cornerRadius: Radius.small + 2, style: .continuous)
            .strokeBorder(node.kind == .thisMac ? Dungeon.ember.opacity(0.7) : Dungeon.cardEdge, lineWidth: node.kind == .thisMac ? 1.5 : 1))
        .opacity(node.state == .offline && node.kind != .server ? 0.7 : 1)
    }

    /// What VoiceOver reads instead of the picture: devices, channels with state and server, Imps with tools.
    @ViewBuilder
    private var structuredList: some View {
        List {
            Section("Devices") {
                ForEach(map.nodes) { node in
                    Text(verbatim: node.kind == .server
                         ? String(localized: "Server \(node.name), \(node.state == .connected ? String(localized: "relaying") : String(localized: "not in use"))")
                         : node.kind == .thisMac ? node.title : "\(node.title), \(node.state.title)")
                }
            }
            Section("Channels") {
                ForEach(map.channels) { channel in
                    Text(verbatim: String(localized: "\(map.node(channel.from)?.name ?? "") to \(map.node(channel.to)?.name ?? ""), \(channel.route), \(channel.state.title)"))
                }
            }
            Section("Imps") {
                ForEach(map.imps) { imp in
                    Text(verbatim: summary(of: imp))
                }
            }
        }
    }

    private func summary(of imp: DeviceMap.ImpEntry) -> String {
        let place = map.node(imp.location)?.name ?? ""
        let tools = ListFormatter.localizedString(byJoining: imp.tools.map(\.title))
        let others = ListFormatter.localizedString(byJoining: imp.talksTo.compactMap { map.imp($0)?.name })
        return String(localized: "\(imp.name), on \(place). Tools: \(tools.isEmpty ? String(localized: "none") : tools). Talks to: \(others.isEmpty ? String(localized: "nobody") : others).")
    }
}

private struct MapLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([DeviceMap.State.connected, .connecting, .offline], id: \.self) { state in
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(verbatim: state.title).font(.system(size: 11)).foregroundStyle(Dungeon.muted)
                }
            }
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

// MARK: Imps

private struct ImpsCard: View {
    let map: DeviceMap

    var body: some View {
        Card("Imps and their tools", icon: "wrench.and.screwdriver.fill",
             info: "What each Imp can use and which Imps it can message, so you don't have to ask. Change them in the Imp's own Tools tab.") {
            ForEach(Array(map.imps.enumerated()), id: \.element.id) { index, imp in
                if index > 0 { CardDivider() }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.imp(imp.hue)).frame(width: 11, height: 11).accessibilityHidden(true)
                        Text(verbatim: imp.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Dungeon.cream)
                        Text(verbatim: place(imp)).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted)
                    }
                    if imp.tools.isEmpty {
                        Text("No tools").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                    } else {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(imp.tools) { tool in chip(tool) }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10.5)).accessibilityHidden(true)
                        Text(verbatim: talk(imp))
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Dungeon.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func place(_ imp: DeviceMap.ImpEntry) -> String {
        imp.location == DeviceMap.thisMacID ? String(localized: "On this Mac")
            : String(localized: "On \(map.node(imp.location)?.name ?? "")")
    }

    private func talk(_ imp: DeviceMap.ImpEntry) -> String {
        let names = imp.talksTo.compactMap { map.imp($0)?.name }
        if names.isEmpty {
            return map.imps.count > 1 ? String(localized: "Doesn't talk to other Imps") : String(localized: "No other Imps to talk to")
        }
        return String(localized: "Can talk to \(ListFormatter.localizedString(byJoining: names))")
    }

    private func chip(_ tool: DeviceMap.Tool) -> some View {
        Label { Text(verbatim: tool.title) } icon: { Image(systemName: tool.symbol) }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tool.source == .mcp ? Dungeon.ember.opacity(0.18) : Color.white.opacity(0.08)))
    }
}
