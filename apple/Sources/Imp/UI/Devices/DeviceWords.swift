import ImpDesign
import ImpKit
import SwiftUI

/// The words and pictures the Devices screen uses for the map's parts. A state is a shape and a word, never
/// colour alone.
extension DeviceMap.State {
    var word: String {
        switch self {
        case .connected: String(localized: "devices.state.connected")
        case .connecting: String(localized: "devices.state.connecting")
        case .offline: String(localized: "devices.state.offline")
        }
    }

    var symbol: String {
        switch self {
        case .connected: "circle.fill"
        case .connecting: "circle.lefthalf.filled"
        case .offline: "circle"
        }
    }

    var tone: Color {
        switch self {
        case .connected: Tone.good
        case .connecting: Tone.warnText
        case .offline: Tone.faint
        }
    }
}

extension HopStanding {
    var word: String {
        switch self {
        case .off: String(localized: "devices.hop.state.off")
        case .needsAddress: String(localized: "devices.hop.state.needs_address")
        case .connecting: DeviceMap.State.connecting.word
        case .connected: DeviceMap.State.connected.word
        case .offline: String(localized: "devices.hop.state.idle")
        case .reachable: String(localized: "servers.state_ok")
        case .unreachable: String(localized: "servers.state_fail")
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle.dashed"
        case .needsAddress: "exclamationmark.circle"
        case .connecting: DeviceMap.State.connecting.symbol
        case .connected: DeviceMap.State.connected.symbol
        case .offline: DeviceMap.State.offline.symbol
        case .reachable: "checkmark.circle.fill"
        case .unreachable: "xmark.octagon.fill"
        }
    }

    var tone: Color {
        switch self {
        case .off: Tone.faint
        case .needsAddress: Tone.warnText
        case .connecting: DeviceMap.State.connecting.tone
        case .connected: DeviceMap.State.connected.tone
        case .offline: DeviceMap.State.offline.tone
        case .reachable: Tone.good
        case .unreachable: Tone.danger
        }
    }
}

extension DeviceMap.Node {
    var symbol: String {
        switch kind {
        case .thisMac: "macbook"
        case .mac: "desktopcomputer"
        case .phone: "iphone.gen3"
        case .server: "arrow.triangle.swap"
        }
    }

    /// What it is called: a device by its name, the Hop by its title.
    var title: String { kind == .server ? String(localized: "servers.hop.title") : name }

    /// The state this node is in, as it is shown. This Mac is always there.
    var shownState: DeviceMap.State { kind == .thisMac ? .connected : state }

    /// A linked device (not this Mac, not the Hop).
    var isLinkedDevice: Bool { kind == .mac || kind == .phone }
}

extension DeviceMap {
    /// One short line for a screen reader: what the node is, its state and the Imps in it.
    func summary(of node: Node, standing: HopStanding? = nil) -> String {
        let imps = residents(of: node.id).map(\.name)
        let what = node.kind == .thisMac ? words("devices.node.this_mac_label", node.title) : node.title
        let state = standing?.word ?? node.shownState.word
        guard !imps.isEmpty else { return words("devices.node.label_empty", what, state) }
        return words("devices.node.label", what, state, imps.formatted(.list(type: .and)))
    }

    /// What the whole picture says, for a screen reader.
    var accessibilitySummary: String {
        let devices = nodes.filter(\.isLinkedDevice).count
        let ours = imps.count
        return words("devices.map.summary", String(devices), String(ours), String(others.count))
    }

    /// How a channel is travelled, in words: the network or the Hop and the address when it has one.
    func route(of channel: Channel) -> String {
        switch channel.path {
        case .local:
            channel.address.map { words("devices.route.local_at", $0) } ?? String(localized: "devices.route.local")
        case .relay:
            channel.address.map { words("devices.route.hop_at", $0) } ?? String(localized: "devices.route.hop")
        }
    }

    /// The short label on the line: Wi-Fi, or the Hop's host.
    func tag(of channel: Channel) -> String {
        switch channel.path {
        case .local: String(localized: "devices.route.tag_local")
        case .relay: channel.server ?? String(localized: "servers.hop.title")
        }
    }

    func title(of id: String) -> String { node(id)?.title ?? String(localized: "devices.unknown_device") }
}
