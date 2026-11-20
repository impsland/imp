import ImpDesign
import ImpKit
import SwiftUI

/// A linked device: how it stands and is reached, the Imps on its screen, what it can use here as plugs, its last known
/// addresses when it is away, and last Forget.
struct LinkedDevicePage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        let peer = ctx.peer(node.id)
        let channel = ctx.map.channels.first { $0.to == node.id }
        StatusLine(symbol: node.state.symbol, tone: node.state.tone,
                   text: ([node.state.word] + (node.state == .offline ? [] : channel.map { [ctx.map.tag(of: $0)] } ?? [])).joined(separator: " · "))
        OnItsScreen(ctx: ctx, node: node.id)
        if let peer {
            PanelSection(LocalizedStringKey(words("devices.plug.title", peer.name)), icon: "powerplug.fill") {
                DevicePlugBoard(model: ctx.model, peer: peer)
            }
        }
        if node.state != .connected, !node.addresses.isEmpty {
            PanelSection("devices.reach.last_seen", icon: "wifi") {
                ChipFlow { ForEach(node.addresses, id: \.self) { Text(verbatim: $0).font(Typeface.mono).textSelection(.enabled) } }
            }
        }
        if let peer {
            SheetActions {
                SheetAction(verbatim: words("devices.forget.named", peer.name), symbol: "xmark.circle", role: .destructive) { ctx.forget(peer) }
            }
        }
    }
}

/// Every Imp whose body is on a device: this Mac's (each with a way home, and one for all), its own and the ones
/// visiting it. Each opens its sheet.
struct OnItsScreen: View {
    let ctx: DeviceContext
    let node: String

    var body: some View {
        let residents = ctx.map.residents(of: node)
        let ours = residents.filter { ctx.map.imp($0.id) != nil }
        if !residents.isEmpty {
            PanelSection("devices.on_screen", icon: "rectangle.on.rectangle", accessory: {
                if ours.count > 1 {
                    HoverIconButton(systemName: "house.fill", help: "devices.call_all_home") { ours.forEach { ctx.model.callHome($0.id) } }
                }
            }, content: {
                ChipFlow {
                    ForEach(residents) { contact in
                        let mine = ctx.map.imp(contact.id) != nil
                        ChipButton(imp: contact, ours: mine, away: contact.home != contact.location,
                                   home: mine && node != ctx.thisMac ? { ctx.model.callHome(contact.id) } : nil) {
                            ctx.select(.imp(contact.id, in: node))
                        }
                    }
                }
            })
        }
    }
}
