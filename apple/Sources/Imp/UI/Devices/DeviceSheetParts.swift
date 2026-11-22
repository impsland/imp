import ImpDesign
import ImpKit
import SwiftUI

/// What the sheets' pages need from the screen: the model, the map as drawn, and how to open another sheet,
/// the Link sheet, or ask to forget a device.
@MainActor
struct DeviceContext {
    let model: AppModel
    let router: HomeRouter
    let map: DeviceMap
    let select: (DeviceSelection?) -> Void
    let link: () -> Void
    let forget: (DeviceLink.Peer) -> Void
    let forgetEveryone: () -> Void
    /// Opens the Hop's sheet.
    let hop: () -> Void

    /// The linked device behind a node.
    func peer(_ node: String) -> DeviceLink.Peer? { model.link.peers.first { $0.id.uuidString == node } }

    func name(of node: String) -> String { map.title(of: node) }

    /// Writes what a linked device may do: the trust and the tool limits.
    func setAccess(_ next: DeviceAccess, for peer: DeviceLink.Peer) {
        let limits = next.limits(applying: model.prefs.deviceToolLimits, peer: peer.id)
        if limits != model.prefs.deviceToolLimits { model.prefs.deviceToolLimits = limits }
        if next.trusted != peer.isTrusted { model.link.setTrusted(peer.id, next.trusted) }
    }

    func symbol(of node: String) -> String { map.node(node)?.symbol ?? "questionmark" }

    var thisMac: String { DeviceMap.thisMacID }

    /// The line between this Mac and the device `node`, the one its plugs are on: through the Hop or direct.
    func connection(to node: String) -> DeviceMap.Channel? {
        map.channels.first { $0.from == node || $0.to == node }
    }
}

// MARK: Parts

/// How a thing stands, in the header of a sheet: a coloured dot and one or two words.
struct StatusPill: View {
    let status: DeviceStatus

    var body: some View {
        HStack(spacing: Spacing.small) {
            Circle().fill(status.tone).frame(width: Spacing.cozy, height: Spacing.cozy)
            Text(verbatim: status.word).font(Typeface.small).foregroundStyle(Tone.text).lineLimit(1)
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.tight)
        .background(Capsule().fill(Tone.card))
        .accessibilityElement(children: .combine)
        .help(status.word)
    }
}

/// A small icon button in a sheet's header for what can be done with the thing: link, send home, settings, forget. Its
/// words are its tooltip and spoken label.
struct HeaderAction: View {
    let symbol: String
    let help: LocalizedStringKey
    var destructive = false
    let action: () -> Void

    var body: some View {
        HoverIconButton(systemName: symbol, help: help, tint: destructive ? Tone.danger : Tone.text, action: action)
    }
}
