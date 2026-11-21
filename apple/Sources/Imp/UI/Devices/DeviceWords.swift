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

extension HopStanding {
    /// The tint of the Hop's button in the screen's bar: good while a channel runs through it or a check reached it,
    /// danger when it is set wrong or unreachable, muted otherwise.
    var barTone: Color {
        switch self {
        case .connected, .reachable: Tone.good
        case .needsAddress, .unreachable: Tone.danger
        case .off, .connecting, .offline: Tone.muted
        }
    }
}

/// One word and a colour: how a thing stands, for the pill in a sheet's header. A word, never colour alone.
struct DeviceStatus {
    var word: String
    var tone: Color
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
    func summary(of node: Node) -> String {
        let imps = residents(of: node.id).map(\.name)
        let what = node.kind == .thisMac ? words("devices.node.this_mac_label", node.title) : node.title
        let state = status(of: node).word
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

    /// How a device stands in one or two words: Here, Nearby, Via server, Away, or Through the device that relays it.
    func status(of node: Node) -> DeviceStatus {
        if node.kind == .thisMac { return DeviceStatus(word: String(localized: "devices.status.here"), tone: Tone.good) }
        if !node.linked {
            return DeviceStatus(word: words("devices.status.through", node.via.map(title(of:)) ?? String(localized: "devices.unknown_device")), tone: Tone.muted)
        }
        guard let channel = channels.first(where: { $0.from == node.id || $0.to == node.id }) else {
            return DeviceStatus(word: node.state.word, tone: node.state.tone)
        }
        return status(of: channel)
    }

    /// How a channel stands: Nearby on the local network, Via server through the Hop, or its state when it is not up.
    func status(of channel: Channel) -> DeviceStatus {
        guard channel.state == .connected else { return DeviceStatus(word: channel.state.word, tone: channel.state.tone) }
        return DeviceStatus(word: String(localized: channel.path == .relay ? "devices.status.via_server" : "devices.status.nearby"), tone: Tone.good)
    }

    func title(of id: String) -> String { node(id)?.title ?? String(localized: "devices.unknown_device") }
}
