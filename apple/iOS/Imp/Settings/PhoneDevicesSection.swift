import ImpDesign
import ImpKit
import SwiftUI

/// The Devices section: This iPhone (its name and the code to link another device), the linked devices
/// (each its own row, Forget all in the header) and The Hop that lets devices find each other.
struct PhoneDevicesSection: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    let scan: () -> Void
    let forget: (LinkDevice) -> Void
    let forgetAll: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Card("phone.name.title", icon: "iphone", info: "devices.this.info") { NameField(hub: hub) }
            LinkCodeCard(hub: hub, problem: $problem, scan: scan)
            devices
            if !elsewhere.isEmpty {
                Card("imp.state.away", icon: "arrow.up.right.circle") {
                    ForEach(elsewhere, id: \.id) { imp in held(imp, by: hub.holders[imp.id].map(hub.deviceName)) }
                }
            }
            ServerCard(hub: hub)
        }
    }

    /// The linked devices, one pebble each. With none, a short empty state.
    private var devices: some View {
        Card("devices.title", icon: "laptopcomputer.and.iphone", info: "devices.list.info") {
            if !hub.links.isEmpty {
                HoverIconButton(systemName: "xmark.circle", help: "settings.devices.forget_all.title", tint: Tone.danger, action: forgetAll)
            }
        } content: {
            if hub.node.status.localNetworkBlocked { LocalNetworkNotice(blocked: true) }
            if hub.links.isEmpty {
                EmptyState("devices.empty", symbol: "laptopcomputer.and.iphone")
            } else {
                ForEach(hub.links) { link in deviceRow(link.device) }
            }
        }
    }

    /// Imps of this iPhone held by a device it isn't linked with (one it passed them on to).
    private var elsewhere: [LinkImp] {
        pocket.looks.filter { imp in
            hub.holders[imp.id].map { holder in !hub.links.contains { $0.id == holder } } ?? false
        }
    }

    /// One linked device as a pebble: icon, name, how it is reached (an icon, hover or VoiceOver for the words),
    /// Forget, then Mine and the Imps it holds.
    private func deviceRow(_ device: LinkDevice) -> some View {
        let holding = pocket.looks.filter { hub.holders[$0.id] == device.id }
        let visiting = hub.visits.filter { $0.home.id == device.id }.map(\.imp.name)
        let connected = hub.isConnected(device.id)
        let reach = !connected ? String(localized: "devices.reach.away")
            : hub.viaHop.contains(device.id) ? String(localized: "devices.reach.server") : String(localized: "devices.reach.direct")
        let reachSymbol = !connected ? "moon.zzz.fill" : hub.viaHop.contains(device.id) ? "arrow.triangle.swap" : "wifi"
        return VStack(spacing: Spacing.small) {
            HStack(spacing: Spacing.cozy) {
                IconTile(systemName: device.kind == .mac ? "macbook" : "iphone").opacity(connected ? 1 : Opacity.dimmed)
                Text(verbatim: device.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.small)
                Image(systemName: reachSymbol).font(.icon(.small)).foregroundStyle(connected ? Tone.good : Tone.muted)
                    .frame(width: Sizing.mark)
                    .accessibilityElement().accessibilityLabel(Text(verbatim: reach))
                HoverIconButton(systemName: "xmark.circle", help: "phone.forget.one", tint: Tone.danger) { forget(device) }
            }
            Row("phone.mine", info: "settings.devices.mine.info") {
                Toggle("phone.mine", isOn: Binding(get: { hub.isTrusted(device.id) }, set: { hub.setTrusted(device.id, $0) }))
                    .toggleStyle(.impSwitchBare)
            }
            ForEach(holding, id: \.id) { held($0, by: nil) }
            if !visiting.isEmpty {
                StatusText(verbatim: words("phone.visiting", visiting.formatted()), symbol: "arrow.down.right.circle")
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity)
        .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// An Imp of this iPhone that another device holds, with the way to call it home.
    private func held(_ imp: LinkImp, by holder: String?) -> some View {
        HStack(spacing: Spacing.cozy) {
            Circle().fill(Color.imp(imp.hue)).frame(width: Spacing.small, height: Spacing.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: imp.name).font(Typeface.label).foregroundStyle(Tone.text)
                if let holder {
                    Text(verbatim: words("phone.with", holder)).font(Typeface.small).foregroundStyle(Tone.muted)
                }
            }
            Spacer(minLength: Spacing.small)
            Button { hub.callHome(imp.id) } label: { FitLabel("phone.callhome", systemImage: "house") }
                .buttonStyle(.secondary)
                .accessibilityLabel(words("phone.callhome.label", imp.name))
        }
        .frame(minHeight: Sizing.hit)
    }
}
