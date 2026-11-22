import ImpDesign
import ImpKit
import SwiftUI

/// This Mac's actions, in the sheet's header: link another device, and forget everyone once anything is linked.
struct ThisMacActions: View {
    let ctx: DeviceContext

    var body: some View {
        HeaderAction(symbol: "qrcode", help: "settings.devices.link.title") { ctx.link() }
            .settingAnchor(.devicesLink)
        if !ctx.model.link.peers.isEmpty {
            HeaderAction(symbol: "trash", help: "settings.devices.forget_all.title", destructive: true) { ctx.forgetEveryone() }
                .settingAnchor(.devicesForgetAll)
        }
    }
}

/// This Mac: where it can be reached and the Imps here, as chips in one flow. What a chip means is its tooltip. The Hop is a
/// button in the screen's bar, not here.
struct ThisMacPage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        if ctx.model.link.status?.localNetworkBlocked == true { LocalNetworkNotice() }
        ChipFlow {
            if node.addresses.isEmpty {
                ChipButton(route: "moon.zzz.fill", title: String(localized: "devices.reach.none"), mono: false, help: "devices.reach.none")
            } else {
                ForEach(node.addresses, id: \.self) { ChipButton(route: "network", title: $0, mono: true, help: "devices.reach.at") }
            }
            ResidentChips(ctx: ctx, node: node.id)
        }
    }
}
