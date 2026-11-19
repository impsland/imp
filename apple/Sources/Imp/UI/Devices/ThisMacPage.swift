import ImpDesign
import ImpKit
import SwiftUI

/// This Mac: whether it can be reached and where, the Local Network notice, Link a device, and last Forget everyone.
struct ThisMacPage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        let reachable = !node.addresses.isEmpty
        StatusLine(symbol: reachable ? "wifi" : "moon.zzz.fill", tone: reachable ? Tone.good : Tone.muted,
                   text: String(localized: reachable ? "devices.reach.yes" : "devices.reach.none"))
        if ctx.model.link.status?.localNetworkBlocked == true { LocalNetworkNotice() }
        SheetActions {
            Button { ctx.link() } label: { FitLabel("settings.devices.link.title", systemImage: "qrcode") }
                .buttonStyle(.imp(.primary, small: true))
                .settingAnchor(.devicesLink)
        }
        if reachable {
            PanelSection("devices.inspector.reach", icon: "wifi") {
                ForEach(node.addresses, id: \.self) { SheetRow($0, symbol: "network", mono: true) }
            }
        }
        if !ctx.model.link.peers.isEmpty {
            SheetActions {
                SheetAction(title: "settings.devices.forget_all.title", symbol: "xmark.circle", role: .destructive) { ctx.forgetEveryone() }
                    .settingAnchor(.devicesForgetAll)
            }
        }
    }
}
