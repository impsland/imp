import ImpDesign
import ImpKit
import SwiftUI

/// A device other than this Mac. A linked one: its connection (opens the line's sheet), Mine, what it may do here,
/// its Imps, and last Forget. One known only through another: its Imps and the way to link it directly. How it stands
/// is the pill in the header, once.
struct LinkedDevicePage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        if node.linked, let peer = ctx.peer(node.id) {
            linked(peer)
        } else {
            SheetActions {
                Button { ctx.link() } label: { FitLabel("settings.devices.link.title", systemImage: "qrcode") }
                    .buttonStyle(.imp(.primary, small: true))
                    .help(Text("devices.link_directly.help"))
            }
            OnItsScreen(ctx: ctx, node: node.id)
        }
    }

    @ViewBuilder private func linked(_ peer: DeviceLink.Peer) -> some View {
        if let channel = ctx.map.channels.first(where: { $0.from == node.id || $0.to == node.id }) {
            SheetLinkRow(title: channel.address ?? ctx.map.tag(of: channel), symbol: channel.path == .relay ? "arrow.triangle.swap" : "wifi",
                         mono: channel.address != nil, help: "devices.reach.at") { ctx.select(.channel(channel.id)) }
        } else if let address = node.addresses.first {
            SheetRow(address, symbol: "wifi", mono: true).help(Text("devices.reach.last_seen"))
        }
        SwitchRow(symbol: DeviceAccess.talkSymbol, title: String(localized: "phone.mine"), info: "settings.devices.mine.info",
                  isOn: Binding(get: { peer.isTrusted }, set: { on in ctx.setAccess(access(peer).plugging(DeviceAccess.talk, on), for: peer) }))
        if peer.isTrusted {
            ToolSwitchCard(title: LocalizedStringKey(words("devices.plug.title", peer.name)), tools: access(peer).tools.map { tool in
                ToolSwitch(id: tool.id, symbol: tool.symbol, title: tool.title, isOn: Binding(
                    get: { access(peer).capabilities.first { $0.id == tool.id }?.allowed ?? false },
                    set: { on in ctx.setAccess(access(peer).plugging(tool.id, on), for: peer) }))
            })
        }
        OnItsScreen(ctx: ctx, node: node.id)
        SheetActions {
            SheetAction(verbatim: words("devices.forget.named", peer.name), symbol: "xmark.circle", role: .destructive) { ctx.forget(peer) }
        }
    }

    private func access(_ peer: DeviceLink.Peer) -> DeviceAccess {
        DeviceAccess.of(peer: peer.id, trusted: peer.isTrusted, prefs: ctx.model.prefs)
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
                if ours.count > 1 && node != ctx.thisMac {
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
