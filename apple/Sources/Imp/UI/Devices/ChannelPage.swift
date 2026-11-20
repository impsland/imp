import ImpDesign
import ImpKit
import SwiftUI

/// A line between this Mac and a device, as a picture and its settings: the two devices joined in the colour of how the
/// line stands (with the Hop between them when it goes through it), what the device can use on it as plugs, the Imps
/// travelling across it, and last Forget. Nothing here leads to the devices at its ends: they have their own sheets.
struct ChannelPage: View {
    let ctx: DeviceContext
    let channel: DeviceMap.Channel

    var body: some View {
        let far = [channel.from, channel.to].first { $0 != ctx.thisMac && ctx.map.node($0)?.kind != .server } ?? channel.to
        let peer = ctx.peer(far)
        let hop = channel.path == .relay
        Diagram {
            DiagramTile(symbol: ctx.symbol(of: ctx.thisMac), name: ctx.name(of: ctx.thisMac))
            DiagramConnector(symbol: hop ? "arrow.triangle.swap" : "wifi", tone: channel.state.tone, dashed: hop,
                             pill: hop ? (channel.server ?? String(localized: "servers.hop.title")) : nil)
            DiagramTile(symbol: ctx.symbol(of: far), name: ctx.name(of: far))
        } footer: { detail }
        if let peer {
            PanelSection(LocalizedStringKey(words("devices.plug.title", peer.name)), icon: "powerplug.fill") {
                DevicePlugBoard(model: ctx.model, peer: peer)
            }
        }
        Travelling(ctx: ctx, channel: channel)
        if let peer {
            SheetActions {
                SheetAction(verbatim: words("devices.forget.named", peer.name), symbol: "xmark.circle", role: .destructive) { ctx.forget(peer) }
            }
        }
    }

    /// How the line stands in a word, and its address in small type only when it is not up (where it was last seen).
    private var detail: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: channel.state.symbol).font(.icon(.tiny)).foregroundStyle(channel.state.tone)
            Text(verbatim: "\(channel.state.word) · \(ctx.map.tag(of: channel))").font(Typeface.small).foregroundStyle(Tone.muted)
            if channel.state == .offline, let address = channel.address {
                Text(verbatim: address).font(Typeface.mono).foregroundStyle(Tone.muted).lineLimit(1).textSelection(.enabled)
            }
        }
    }
}

/// The Imps going across a line: this Mac's whose bodies are on the far device (arrow out) and the device's own
/// Imps here (arrow back). Each opens its sheet. One way home for all of ours sits in the card's corner.
struct Travelling: View {
    let ctx: DeviceContext
    let channel: DeviceMap.Channel

    var body: some View {
        let travellers = ctx.map.travellers(of: channel)
        if !travellers.out.isEmpty || !travellers.in.isEmpty {
            PanelSection("devices.edge.travelling", icon: "figure.walk", accessory: {
                if !travellers.out.isEmpty {
                    HoverIconButton(systemName: "house.fill", help: "devices.call_all_home") { travellers.out.forEach { ctx.model.callHome($0.id) } }
                }
            }, content: {
                ChipFlow {
                    ForEach(travellers.out) { contact in
                        ChipButton(imp: contact, ours: true, arrow: "arrow.right", home: { ctx.model.callHome(contact.id) }) {
                            ctx.select(.imp(contact.id, in: contact.location))
                        }
                    }
                    ForEach(travellers.in) { contact in
                        ChipButton(imp: contact, ours: false, arrow: "arrow.left") { ctx.select(.imp(contact.id, in: contact.location)) }
                    }
                }
            })
        }
    }
}
