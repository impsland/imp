import ImpDesign
import ImpKit
import SwiftUI

/// This Mac: whether it can be reached and where, the Local Network notice, the Hop (the way to set one up, as it
/// is on the canvas only when a line goes through it), and the two actions for the link: Link a device and Forget everyone.
struct ThisMacPage: View {
    let ctx: DeviceContext
    let node: DeviceMap.Node

    var body: some View {
        let reachable = !node.addresses.isEmpty
        StatusLine(symbol: reachable ? "wifi" : "moon.zzz.fill", tone: reachable ? Tone.good : Tone.muted,
                   text: String(localized: reachable ? "devices.reach.yes" : "devices.reach.none"))
        if ctx.model.link.status?.localNetworkBlocked == true { LocalNetworkNotice() }
        if reachable {
            PanelSection("devices.reach.at", icon: "network") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(node.addresses, id: \.self) { Text(verbatim: $0).font(Typeface.mono).textSelection(.enabled).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        hopRow
        SheetActions {
            Button { ctx.link() } label: { FitLabel("settings.devices.link.title", systemImage: "qrcode") }
                .buttonStyle(.imp(.primary, small: true))
                .settingAnchor(.devicesLink)
            if !ctx.model.link.peers.isEmpty {
                SheetAction(title: "settings.devices.forget_all.title", symbol: "xmark.circle", role: .destructive) { ctx.forgetEveryone() }
                    .settingAnchor(.devicesForgetAll)
            }
        }
    }

    /// The Hop with how it stands, or the way to add one. It opens the Hop's sheet.
    private var hopRow: some View {
        let hop = HopServer(ctx.model.prefs.hop)
        let standing = ctx.map.hopStanding(text: ctx.model.prefs.hop)
        return Button { ctx.hop() } label: {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: "arrow.triangle.swap").font(.icon(.small)).foregroundStyle(Tone.text)
                Text(verbatim: hop.map { words("devices.hop.pill", $0.host) } ?? String(localized: "devices.hop.add"))
                    .font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Spacing.small)
                if hop != nil {
                    Image(systemName: standing.symbol).font(.icon(.tiny)).foregroundStyle(standing.tone)
                    Text(verbatim: standing.word).font(Typeface.small).foregroundStyle(Tone.muted)
                }
                Image(systemName: "chevron.right").font(.icon(.tiny)).foregroundStyle(Tone.faint).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pebble(hover: true)
    }
}
