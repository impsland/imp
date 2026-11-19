import ImpDesign
import ImpKit
import SwiftUI

/// A channel: how it stands and goes, a way to each end and to the Hop it passes through, and last Forget.
struct ChannelPage: View {
    let ctx: DeviceContext
    let channel: DeviceMap.Channel

    var body: some View {
        StatusLine(symbol: channel.state.symbol, tone: channel.state.tone, text: "\(channel.state.word) · \(ctx.map.route(of: channel))")
        VStack(spacing: Spacing.small) {
            ForEach([channel.from, channel.to], id: \.self) { end in
                JumpRow(ctx.name(of: end), symbol: ctx.symbol(of: end)) { ctx.select(.node(end)) }
            }
            if channel.path == .relay, let via = channel.via {
                JumpRow(ctx.name(of: via), symbol: "arrow.triangle.swap") { ctx.select(.node(via)) }
            }
        }
        if let peer = [channel.from, channel.to].lazy.compactMap({ ctx.peer($0) }).first {
            SheetActions { SheetAction(title: "devices.forget.one", symbol: "xmark.circle", role: .destructive) { ctx.forget(peer) } }
        }
    }
}

/// A tether: an Imp that is on one device and thinks on another, with the tools it may use where it is.
struct TetherPage: View {
    let ctx: DeviceContext
    let contact: DeviceMap.Contact
    let node: String

    var body: some View {
        PlaceRows(ctx: ctx, on: node, thinksOn: contact.home)
        if ctx.map.imp(contact.id) != nil {
            SheetActions { SheetAction(title: "settings.devices.call_home", symbol: "house") { ctx.model.callHome(contact.id) } }
        }
        if let entry = ctx.map.imp(contact.id), let peer = ctx.peer(node) {
            if peer.isTrusted {
                let allowed = entry.tools.filter { ctx.model.prefs.deviceToolLimits.isAllowed(group: $0.id, on: peer.id) }
                if !allowed.isEmpty {
                    PanelSection("devices.tether.tools", icon: "wrench.and.screwdriver.fill", info: "devices.tether.tools.info") {
                        ToolStrip(tools: allowed.map { ($0.symbol, $0.title) })
                    }
                }
            } else {
                SheetRow(title: String(localized: "devices.tools.locked"), leading: { IconTile(systemName: "lock.fill") },
                         trailing: { InfoTip("devices.tools.not_mine") })
            }
        }
    }
}
