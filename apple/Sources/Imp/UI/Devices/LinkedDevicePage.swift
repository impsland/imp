import ImpDesign
import ImpKit
import SwiftUI

/// A device other than this Mac, in the sheet's header. A linked one: send its Imps home, and forget it. One known only
/// through another: link it directly.
struct LinkedDeviceActions: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        if node.linked, let peer = ctx.peer(node.id) {
            if ours.count > 1 {
                HeaderAction(symbol: "house.fill", help: "devices.call_all_home") { ours.forEach { ctx.model.callHome($0.id) } }
            }
            HeaderAction(symbol: "trash", help: LocalizedStringKey(words("devices.forget.named", peer.name)), destructive: true) { ctx.forget(peer) }
        } else {
            HeaderAction(symbol: "qrcode", help: "devices.link_directly.help") { ctx.link() }
        }
    }

    /// The Imps of this Mac whose body is on the device.
    private var ours: [DeviceMap.Contact] { ctx.map.residents(of: node.id).filter { ctx.map.imp($0.id) != nil } }
}

/// A device other than this Mac. A linked one: how it is connected (opens the line's sheet) and its Imps as chips in one
/// flow, then what it may do here: Mine, and while it is Mine, which tools. One known only through another: its Imps. How it
/// stands is the pill in the header, once.
struct LinkedDevicePage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        if node.linked, let peer = ctx.peer(node.id) {
            ChipFlow {
                connection
                ResidentChips(ctx: ctx, node: node.id)
            }
            AccessCard(ctx: ctx, peer: peer)
        } else {
            ChipFlow { ResidentChips(ctx: ctx, node: node.id) }
        }
    }

    /// The line to this device: its address (or the Hop's name), which opens the line's sheet.
    @ViewBuilder private var connection: some View {
        if let channel = ctx.connection(to: node.id) {
            ChipButton(route: channel.path == .relay ? "arrow.triangle.swap" : "wifi", title: channel.address ?? ctx.map.tag(of: channel),
                       mono: channel.address != nil, help: "devices.reach.at") { ctx.select(.channel(channel.id)) }
        } else if let address = node.addresses.first {
            ChipButton(route: "wifi", title: address, mono: true, help: "devices.reach.last_seen")
        }
    }
}

/// What a linked device may do with this Mac's Imps: the Mine switch in the header, and while it is on the tools it may
/// use, as switches (`DeviceAccess`).
private struct AccessCard: View {
    let ctx: DeviceContext
    let peer: DeviceLink.Peer

    private var access: DeviceAccess { DeviceAccess.of(peer: peer.id, trusted: peer.isTrusted, prefs: ctx.model.prefs) }

    var body: some View {
        Card("phone.mine", icon: DeviceAccess.talkSymbol, info: "settings.devices.mine.info", accessory: {
            Toggle(isOn: Binding(get: { peer.isTrusted }, set: { on in ctx.setAccess(access.plugging(DeviceAccess.talk, on), for: peer) })) {
                Text("phone.mine")
            }
            .labelsHidden().toggleStyle(.impSwitchBare)
        }, content: {
            if peer.isTrusted {
                ToolGrid(items: access.tools.map { ToolItem(id: $0.id, symbol: $0.symbol, title: $0.title, on: $0.allowed) }) { ids, on in
                    ctx.setAccess(ids.reduce(access) { $0.plugging($1, on) }, for: peer)
                }
            }
        })
    }
}

/// The Imps whose body is on a device: this Mac's (each with a way home when the device is another) and the ones visiting
/// it, as chips that each open their sheet. For the inside of a `ChipFlow`.
struct ResidentChips: View {
    let ctx: DeviceContext
    let node: String

    var body: some View {
        ForEach(ctx.map.residents(of: node)) { contact in
            let mine = ctx.map.imp(contact.id) != nil
            ChipButton(imp: contact, ours: mine, away: contact.home != contact.location,
                       home: mine && node != ctx.thisMac ? { ctx.model.callHome(contact.id) } : nil) {
                ctx.select(.imp(contact.id, in: node))
            }
        }
    }
}
