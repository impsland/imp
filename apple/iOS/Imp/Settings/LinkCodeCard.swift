import ImpDesign
import ImpKit
import SwiftUI

/// Link a device, in one card: this iPhone's code (the QR code and a line, with Copy and Share), and Scan and
/// Paste for another device's. The code is shown only when asked for (Show code), because showing it is what
/// brings up the local network, and so the Local Network permission: opening Devices to look never asks.
/// Once asked for, the code shows whenever Devices opens. Showing it again shows the same code while it
/// works (15 minutes after it was last on screen), so a copied link stays good. A bad code floats as a notice
/// instead of moving anything.
struct LinkCodeCard: View {
    let hub: LinkHub
    @Binding var problem: String?
    let scan: () -> Void
    /// Shows the code at once (a sheet opened just to link) instead of waiting for Show code.
    var showsAtOnce = false
    @State private var showing = false
    /// The person asked for the code once: from then on it shows at once (the Local Network was asked then).
    @AppStorage("link.code.shown") private var shownBefore = false
    @State private var invite: LinkInvite?
    @State private var copied: ActionState = .idle
    private var status: LinkStatus { hub.node.status }

    /// What a code depends on: made again whenever it changes.
    private struct Basis: Hashable {
        var routes: LinkStatus.Routes
        var running: Bool
        var locked: Bool
        var showing: Bool
    }
    @Environment(\.postNotice) private var post

    var body: some View {
        Card("settings.devices.pair.title", icon: "qrcode", info: "phone.linked.info") {
            VStack(spacing: Spacing.medium) {
                if showing { code } else {
                    Button { showing = true; shownBefore = true } label: { FitLabel("devices.show", systemImage: "qrcode").frame(maxWidth: .infinity) }
                        .buttonStyle(.imp(.primary))
                }
                HStack(spacing: Spacing.small) { scanButton; pasteButton }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: Basis(routes: status.routes, running: status.running, locked: hub.isLocked, showing: showing)) {
            // Showing a code is what needs the local network: asked for here, when the person asks for the
            // code, never at launch or on opening Devices. The code is made again when its routes change
            // (started, Wi-Fi changed, Hop set or cleared), and never shown without a way to reach this iPhone.
            guard showing else { return }
            await hub.useNetwork()
            invite = hub.node.status.isReady ? hub.node.invite() : nil
        }
        .onAppear { if showsAtOnce || shownBefore { showing = true } }
        .onDisappear { if showing { hub.node.inviteHidden() } }
        .onChange(of: problem) { _, text in
            guard let text else { return }
            post(.error(text))
            problem = nil
        }
    }

    /// The QR code with its line, the Local Network state, then Copy and Share.
    @ViewBuilder private var code: some View {
        if let invite, let image = QRCode.image(for: invite.url.absoluteString) {
            Image(image, scale: 1, label: Text("phone.code.label"))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .blendMode(.multiply)        // the picture's white takes the paper's tone
                .frame(maxWidth: Sizing.tipWidth)
                .padding(Spacing.medium)
                // A QR code is read as dark on light, whatever the app's colours: on paper in both appearances.
                .background(Tone.paper, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                .compositingGroup()
                .accessibilityLabel("phone.code.label")
                .accessibilityIdentifier("link.code")
                #if DEBUG
                // For the UI tests on a device: the code's link, to tell a kept code from a new one and to link a test
                // page with it. Never in a release.
                .accessibilityValue(invite.url.absoluteString)
                #endif
            Text("phone.code.caption").font(Typeface.caption).foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
        } else {
            ProgressView().frame(minHeight: Sizing.tipWidth)
                }
                LocalNetworkNotice(blocked: status.localNetworkBlocked, waiting: invite == nil)
                HStack(spacing: Spacing.small) { copy; share }
                    .disabled(invite == nil)
    }

    @ViewBuilder private var copy: some View {
        if let invite {
            Button {
                UIPasteboard.general.string = invite.url.absoluteString
                hub.stayOnlineBriefly()
                copied = .done
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                StatefulLabel("phone.copy", symbol: "doc.on.doc", state: copied).frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .impActionState($copied)
        }
    }

    @ViewBuilder private var share: some View {
        if let invite {
            ShareLink(item: invite.url) { FitLabel("phone.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                .buttonStyle(.secondary)
                .simultaneousGesture(TapGesture().onEnded { hub.stayOnlineBriefly() })
        }
    }

    @ViewBuilder private var scanButton: some View {
        if CodeScanner.isAvailable {
            Button { problem = nil; scan() } label: { FitLabel("phone.scan.code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }
                .buttonStyle(.secondary)
        }
    }

    private var pasteButton: some View {
        Button { problem = LinkClipboard.join(hub) } label: { FitLabel("phone.paste.link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
            .buttonStyle(.secondary)
    }
}

/// One line under a code: why there is none yet. When Local Network is off it says so, with a button
/// that opens this app's page in Settings.
struct LocalNetworkNotice: View {
    let blocked: Bool
    var waiting = false

    var body: some View {
        VStack(spacing: Spacing.small) {
            StatusSlot(blocked ? String(localized: "link.localnet.off") : waiting ? String(localized: "link.preparing") : nil,
                       symbol: blocked ? "exclamationmark.triangle.fill" : nil,
                       color: blocked ? Tone.warnText : Tone.muted)
            if blocked {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: { FitLabel("link.localnet.open", systemImage: "gear").frame(maxWidth: .infinity) }
                    .buttonStyle(.secondary)
            }
        }
    }
}
