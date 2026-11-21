import ImpDesign
import ImpKit
import SwiftUI

/// This Mac: the way to link another device, where it can be reached, the Imps here, and last Forget everyone. What a
/// row means is its tooltip. The Hop is a button in the screen's bar, not here.
struct ThisMacPage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        if ctx.model.link.status?.localNetworkBlocked == true { LocalNetworkNotice() }
        SheetActions {
            Button { ctx.link() } label: { FitLabel("settings.devices.link.title", systemImage: "qrcode") }
                .buttonStyle(.imp(.primary, small: true))
                .help(Text("devices.this.info"))
                .settingAnchor(.devicesLink)
        }
        if node.addresses.isEmpty {
            SheetRow(String(localized: "devices.reach.none"), symbol: "moon.zzz.fill")
        } else {
            ForEach(node.addresses, id: \.self) { SheetRow($0, symbol: "network", mono: true).help(Text("devices.reach.at")) }
        }
        OnItsScreen(ctx: ctx, node: node.id)
        if !ctx.model.link.peers.isEmpty {
            SheetActions {
                SheetAction(title: "settings.devices.forget_all.title", symbol: "xmark.circle", role: .destructive) { ctx.forgetEveryone() }
                    .settingAnchor(.devicesForgetAll)
            }
        }
    }
}
