import ImpDesign
import ImpKit
import SwiftUI

/// The Devices section: the name and the code to link another device, The Hop that lets devices find
/// each other, and the devices already linked with their Imps.
struct PhoneDevicesSection: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    let scan: () -> Void
    let forget: (LinkDevice) -> Void
    let forgetAll: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(spacing: Spacing.medium) {
            Card("phone.name.title", icon: "iphone") { NameField(hub: hub) }
            LinkCodeCard(hub: hub)
            Card("settings.devices.pair.title", icon: "qrcode.viewfinder", info: "phone.linked.info") {
                if let problem { IssueBadge(text: problem, opensAtOnce: true) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.small) { scanButton; pasteButton }
                    VStack(spacing: Spacing.small) { scanButton; pasteButton }
                }
            }
            .impAnimation(ImpDesign.Motion.smooth, value: problem)
            ServerCard(hub: hub, kind: .hop)
            ForEach(hub.links) { link in deviceCard(link.device) }
            if !elsewhere.isEmpty {
                Card("imp.state.away", icon: "arrow.up.right.circle") {
                    ForEach(elsewhere, id: \.id) { imp in held(imp, by: hub.holders[imp.id].map(hub.deviceName)) }
                }
            }
            if !hub.links.isEmpty {
                Button(action: forgetAll) { FitLabel("phone.forget.everyone", systemImage: "xmark.circle") }
                    .buttonStyle(.destructive)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var scanButton: some View {
        if CodeScanner.isAvailable {
            Button { problem = nil; scan() } label: { FitLabel("phone.scan.code", systemImage: "qrcode.viewfinder") }
                .buttonStyle(.imp(.primary))
        }
    }

    private var pasteButton: some View {
        Button { problem = LinkClipboard.join(hub) } label: { FitLabel("phone.paste.link", systemImage: "doc.on.clipboard") }
            .buttonStyle(.secondary)
    }

    /// Imps of this iPhone held by a device it isn't linked with (one it passed them on to).
    private var elsewhere: [LinkImp] {
        pocket.looks.filter { imp in
            hub.holders[imp.id].map { holder in !hub.links.contains { $0.id == holder } } ?? false
        }
    }

    private func deviceCard(_ device: LinkDevice) -> some View {
        let holding = pocket.looks.filter { hub.holders[$0.id] == device.id }
        let visiting = hub.visits.filter { $0.home.id == device.id }.map(\.imp.name)
        return Card {
            HStack(spacing: Spacing.medium) {
                IconTile(systemName: device.kind == .mac ? "macbook" : "iphone", filled: true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(verbatim: device.name).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                        .accessibilityAddTraits(.isHeader)
                    status(of: device)
                }
                Spacer(minLength: Spacing.small)
                Button { forget(device) } label: { FitLabel("phone.forget.one", systemImage: "xmark.circle") }
                    .buttonStyle(.quiet)
            }
            Row("phone.mine", icon: "person.fill.checkmark", info: "privacy.trust_note") {
                Toggle("phone.mine", isOn: Binding(get: { hub.isTrusted(device.id) }, set: { hub.setTrusted(device.id, $0) }))
                    .toggleStyle(.impSwitchBare)
            }
            ForEach(holding, id: \.id) { held($0, by: nil) }
            if !visiting.isEmpty {
                StatusText(verbatim: words("phone.visiting", visiting.formatted()), symbol: "arrow.down.right.circle")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func status(of device: LinkDevice) -> some View {
        let connected = hub.isConnected(device.id)
        let text = !connected ? String(localized: "imp.state.away")
            : hub.viaHop.contains(device.id) ? String(localized: "phone.connected_hop") : String(localized: "phone.connected")
        return StatusText(verbatim: text, symbol: connected ? "circle.fill" : "circle", color: connected ? Tone.good : Tone.muted)
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
