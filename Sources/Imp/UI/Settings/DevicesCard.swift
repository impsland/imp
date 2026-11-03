import AppKit
import CoreImage.CIFilterBuiltins
import ImpDesign
import ImpKit
import SwiftUI

/// Settings › Devices: this Mac's code, the devices it is linked with, and the server that lets
/// them find each other from anywhere. The map above it shows the same devices as a picture.
struct DevicesCard: View {
    let model: AppModel
    @State private var showingCode = false
    @State private var joining = false
    @State private var forgetting: DeviceLink.Peer?
    @State private var forgettingEveryone = false
    private var link: DeviceLink { model.link }

    var body: some View {
        Card("Link devices", icon: "iphone.gen3",
             info: "Link this Mac with your iPhone or another Mac. Throw an Imp hard at the left or right side of your screen and it flies onto a linked device. It still thinks on this Mac: chat with it there, and throw it back. Mark a device as yours (Mine) and the Imps on it may use their tools on this Mac. Others can only talk.") {
            Row("This Mac's code", info: "Shows a code for another device to scan. Each scan links that device with this Mac.") {
                Button { showingCode = true } label: { Label("Show Code…", systemImage: "qrcode") }
                    .buttonStyle(.imp(link.isLinked ? .secondary : .primary, small: true))
            }
            CardDivider()
            Row("Link with another device", info: "Scan the code another device shows with this Mac's camera, or paste its link.") {
                Button { joining = true } label: { Label("Scan Code…", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.imp(.secondary, small: true))
            }
            ForEach(link.peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { peer in
                CardDivider()
                let imps = model.prefs.imps.filter { peer.imps.contains($0.id) }.map(\.name)
                Row(LocalizedStringKey(stringLiteral: peer.name),
                    info: imps.isEmpty ? nil : LocalizedStringKey(String(localized: "Has: \(ListFormatter.localizedString(byJoining: imps))"))) {
                    HStack(spacing: 10) {
                        Image(systemName: peer.kind == .mac ? "desktopcomputer" : "iphone.gen3")
                            .foregroundStyle(Dungeon.muted)
                            .accessibilityHidden(true)
                        switch peer.reach {
                        case .direct: StatusText(text: "Connected on the local network", symbol: "circle.fill", color: .green)
                        case .viaServer:
                            StatusText(verbatim: ImpServer(model.prefs.server).map { String(localized: "Connected through \($0.hopHost)") }
                                       ?? String(localized: "Connected through the server"), symbol: "circle.fill", color: .green)
                        case .away: StatusText(text: "Away", symbol: "circle.fill", color: Dungeon.muted)
                        }
                        Toggle("Mine", isOn: Binding(get: { peer.isTrusted }, set: { link.setTrusted(peer.id, $0) }))
                            .toggleStyle(.impSwitch).fixedSize()
                            .help("Trust: Imps visiting it may use their tools on this Mac, and it may fetch files they mention.")
                        InfoTip("Switch on only for your own devices. A device that isn't yours can still chat with the Imps it holds, but they answer without their tools (no commands, no control of this Mac), and it only gets files from the Imp's own folder.")
                        Button(role: .destructive) { forgetting = peer } label: { Label("Forget…", systemImage: "xmark.circle") }
                            .buttonStyle(.imp(.destructive, small: true))
                    }
                }
            }
            if let problem = link.problem {
                CardDivider()
                StatusText(verbatim: problem, symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            if link.isLinked {
                CardDivider()
                Row("Forget everyone", info: "Unlinks every device and makes the old codes stop working.") {
                    Button(role: .destructive) { forgettingEveryone = true } label: { Label("Forget Everyone…", systemImage: "xmark.circle") }
                        .buttonStyle(.imp(.destructive, small: true))
                }
            }
            CardDivider()
            Row("Server", info: "With a server, your devices find each other from anywhere, not just on your Wi-Fi, and this Mac's code works from anywhere too. The server only passes encrypted data along. It can't read anything.") {
                TextField(String("imp.example.org"), text: Binding(get: { model.prefs.server }, set: { model.prefs.server = $0 }))
                    .impField(mono: true).autocorrectionDisabled().frame(width: 220)
            }
            if !model.prefs.server.isEmpty, ImpServer(model.prefs.server) == nil {
                StatusText(text: "That isn't a server address. Use a host name such as imp.example.org.", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
        }
        .sheet(isPresented: $showingCode) { PairingSheet(model: model) }
        .sheet(isPresented: $joining) { JoinSheet(model: model) }
        .confirmationDialog(forgetting.map { String(localized: "Forget \($0.name)?") } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { peer in
            Button("Forget \(peer.name)", role: .destructive) { link.forget(peer.id) }
        } message: { _ in
            Text("Imps it holds come back to your desktop. To link again, one of you shows a new code.")
        }
        .confirmationDialog("Forget every device?", isPresented: $forgettingEveryone, titleVisibility: .visible) {
            Button("Forget Everyone", role: .destructive) { link.forgetEveryone() }
        } message: {
            Text("Imps on other devices come back to your desktop. The old codes stop working; link again with a new one.")
        }
    }
}

/// Link with another device: hold its code up to this Mac's camera, or paste its link (or a picture
/// of its code, such as a screenshot).
struct JoinSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = CodeScanner()
    @State private var text = ""
    @State private var joining = false
    @State private var error: String?
    @State private var linked: String?

    private var invite: LinkInvite? { LinkInvite(string: text) }

    var body: some View {
        SheetScaffold(icon: "qrcode.viewfinder", title: "Link with a device",
                      info: "Show the code on the other device and hold it up to this Mac's camera, or paste its link.") {
            VStack(alignment: .leading, spacing: 12) {
                viewfinder
                TextField(String("implink://join?…"), text: $text)
                    .impField(mono: true).autocorrectionDisabled()
                    .disabled(joining || linked != nil)
                if let linked {
                    StatusText(verbatim: String(localized: "Linked with \(linked)."), symbol: "checkmark.circle.fill", color: .green)
                } else if let error {
                    StatusText(verbatim: error, symbol: "exclamationmark.triangle.fill", color: .orange)
                } else if !text.isEmpty, invite == nil {
                    StatusText(text: "That isn't a link from Imp.", symbol: "exclamationmark.triangle.fill", color: .orange)
                } else if joining {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Linking…").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                    }
                }
            }
        } footer: {
            Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.imp(.secondary))
                .disabled(joining || linked != nil)
                .help("Pastes a link, or a picture of a code")
            Spacer()
            if linked == nil { SheetCancelButton { dismiss() } }
            if linked != nil {
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            } else {
                Button { invite.map(join) } label: { Label("Link", systemImage: "link") }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(invite == nil || joining)
            }
        }
        .task { await scanner.start { found($0) } }
        .onDisappear { scanner.stop() }
    }

    /// The camera, with a frame to aim the code at, or why there's no picture.
    private var viewfinder: some View {
        ZStack {
            Color.black
            switch scanner.state {
            case .starting:
                ProgressView().controlSize(.small)
            case .scanning:
                CameraPreview(session: scanner.session)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(linked != nil ? Color.green : Dungeon.flame, style: StrokeStyle(lineWidth: 3, dash: [22, 12]))
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.5), radius: 6)
                    .accessibilityHidden(true)
            case .denied:
                VStack(spacing: 10) {
                    Text("Imp may not use the camera.").font(.system(size: 13)).foregroundStyle(Dungeon.cream)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(CodeScanner.privacySettings) }
                        .buttonStyle(.imp(.secondary, small: true))
                }
            case .noCamera:
                Text("This Mac has no camera. Paste the link instead.").font(.system(size: 13)).foregroundStyle(Dungeon.cream)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera")
    }

    /// A code the camera saw: an Imp code links at once, anything else is ignored.
    private func found(_ code: String) {
        guard !joining, linked == nil, let invite = LinkInvite(string: code) else { return }
        text = code
        join(invite)
    }

    private func paste() {
        error = nil
        let pasteboard = NSPasteboard.general
        if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            text = string
        } else if let picture = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let code = CodeScanner.codes(in: picture).first(where: { LinkInvite(string: $0) != nil }) {
            text = code
        } else {
            error = String(localized: "There's no Imp link or code to paste.")
        }
    }

    private func join(_ invite: LinkInvite) {
        error = nil
        joining = true
        Task {
            defer { joining = false }
            do { linked = try await model.link.join(invite).name } catch { self.error = DeviceLink.message(error) }
        }
    }
}

/// This Mac's code: a QR code for another device's camera, the link itself to copy, and who joined.
struct PairingSheet: View {
    let model: AppModel
    /// Shown instead of this Mac's own code (design renders: nothing is listened for).
    var preview: LinkInvite?
    @Environment(\.dismiss) private var dismiss
    @State private var invite: LinkInvite?
    @State private var copied = false
    @State private var before: Set<UUID> = []

    var body: some View {
        SheetScaffold(icon: "iphone.gen3", title: "Link a device",
                      info: "The code holds a key only this Mac and the device that scans it will share. Everything they say to each other is encrypted, and nobody else can link with this Mac without a code you showed them.") {
            HStack(alignment: .center, spacing: 18) {
                Group {
                    if let image = invite.flatMap({ Self.qr($0.url.absoluteString) }) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 188, height: 188)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                .accessibilityLabel("Linking code")
                VStack(alignment: .leading, spacing: 0) {
                    step(1, icon: "iphone.gen3", "**Open** Imp on your other device")
                    connector
                    step(2, icon: "qrcode.viewfinder", "**Scan** this code, or paste its link")
                    connector
                    step(3, icon: "hand.draw.fill", "**Throw** an Imp off your screen")
                    Group {
                        if let newcomer {
                            StatusText(verbatim: String(localized: "\(newcomer) is linked."), symbol: "checkmark.circle.fill", color: .green)
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Waiting for your other device…").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                            }
                        }
                    }
                    .padding(.top, 16)
                    .animation(.snappy, value: newcomer)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Dungeon.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(Dungeon.cardEdge))
        } footer: {
            Button {
                guard let invite else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                copied = true
            } label: { Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") }
                .buttonStyle(.imp(.secondary))
                .help("For a device that can't scan: paste the link in Scan Code… on the other device. Keep it private: it lets a device link with this Mac for a while.")
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            before = Set(model.link.peers.map(\.id))
            invite = preview ?? model.link.invite()
        }
        .onDisappear { if preview == nil { model.link.inviteHidden() } }
    }

    /// A device that linked while the code was up.
    private var newcomer: String? {
        model.link.peers.first { !before.contains($0.id) }?.name
    }

    /// One step on one line, as the iPhone shows them: an icon with its number, a short phrase with
    /// the key word in bold.
    private func step(_ n: Int, icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Dungeon.flame)
                .frame(width: 32, height: 32)
                .background(Dungeon.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Text(verbatim: "\(n)")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(Dungeon.deep)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Dungeon.flame))
                        .offset(x: 5, y: -5)
                }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Dungeon.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// A faint dotted line from one step's icon to the next.
    private var connector: some View {
        Rectangle()
            .fill(Dungeon.ember.opacity(0.35))
            .frame(width: 1.5, height: 9)
            .mask(VStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().frame(height: 2) } })
            .padding(.leading, 15.25)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
    }

    /// A crisp QR code for `text` (medium error correction).
    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
