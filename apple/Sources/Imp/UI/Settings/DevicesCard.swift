import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The devices this Mac is linked with, in one card: Link a device (one sheet that shows this Mac's code
/// or reads another device's), then each linked device with how it is reached and what it may do, and
/// Forget all at the end.
struct DevicesCard: View {
    let model: AppModel
    @State private var linking: LinkDeviceSheet.Mode?
    @State private var forgetting: DeviceLink.Peer?
    @State private var forgettingEveryone = false
    private var link: DeviceLink { model.link }

    var body: some View {
        Card("settings.devices.link.title", icon: "iphone.gen3", info: "settings.devices.link.info") {
            Row("settings.devices.pair.title", icon: "qrcode") {
                HStack(spacing: Spacing.small) {
                    Button { linking = .scan } label: { FitLabel("devices.scan", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(.imp(.secondary, small: true))
                    Button { linking = .show } label: { FitLabel("devices.show", systemImage: "qrcode") }
                        .buttonStyle(.imp(link.isLinked ? .secondary : .primary, small: true))
                }
            }
            .settingAnchor(.devicesPair)
            if let problem = link.problem {
                StatusText(verbatim: problem, symbol: "exclamationmark.triangle.fill", color: Tone.warnText).help(problem)
            }
            let peers = LinkedDevices.sorted(link.peers)
            if peers.isEmpty {
                Text("devices.none").font(Typeface.body).foregroundStyle(Tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.snug)
            } else {
                VStack(spacing: Spacing.snug) {
                    ForEach(peers) { peer in peerRow(peer) }
                }
                Row("settings.devices.forget_all.title", icon: "xmark.circle.fill") {
                    Button(role: .destructive) { forgettingEveryone = true } label: { FitLabel("Forget Everyone…", systemImage: "xmark.circle") }
                        .buttonStyle(.imp(.destructive, small: true))
                }
                .settingAnchor(.devicesForgetAll)
            }
        }
        .settingAnchor(.devicesLink)
        .sheet(item: $linking) { mode in LinkDeviceSheet(model: model, mode: mode) }
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

    /// One linked device as a pebble: what it is, how it is reached and which Imps are on it, then its
    /// controls (beside them when there is room, under them when there is not).
    private func peerRow(_ peer: DeviceLink.Peer) -> some View {
        let reach = LinkedDevices.reach(peer, hop: HopServer(model.prefs.hop))
        let imps = model.prefs.imps.filter { peer.imps.contains($0.id) }.map(\.name)
        let who = HStack(spacing: Spacing.cozy) {
            IconTile(systemName: LinkedDevices.symbol(peer.kind)).opacity(peer.isConnected ? 1 : Opacity.dimmed)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(verbatim: peer.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                StatusText(verbatim: reach.text, symbol: "circle.fill", color: reach.connected ? Tone.good : Tone.muted)
                if !imps.isEmpty {
                    Text(words("devices.has", ListFormatter.localizedString(byJoining: imps)))
                        .font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(2)
                }
            }
        }
        let controls = HStack(spacing: Spacing.small) {
            Toggle("Mine", isOn: Binding(get: { peer.isTrusted }, set: { link.setTrusted(peer.id, $0) }))
                .toggleStyle(.impSwitch).fixedSize()
            InfoTip("settings.devices.mine.info")
            HoverIconButton(systemName: "xmark.circle", help: "Forget…", tint: Tone.danger) { forgetting = peer }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.cozy) {
                who
                Spacer(minLength: Spacing.small)
                controls
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                who
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pebble()
    }
}

/// What the device list says, worked out from the link alone (tested in `ImpTests`).
enum LinkedDevices {
    /// A to Z by name.
    static func sorted(_ peers: [DeviceLink.Peer]) -> [DeviceLink.Peer] {
        peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func symbol(_ kind: LinkKind) -> String { kind == .mac ? "desktopcomputer" : "iphone.gen3" }

    /// How a device is reached, in words, and whether it is connected at all.
    static func reach(_ peer: DeviceLink.Peer, hop: HopServer?) -> (text: String, connected: Bool) {
        switch peer.reach {
        case .direct: (String(localized: "Connected on the local network"), true)
        case .viaServer: (hop.map { String(localized: "Connected through \($0.host)") } ?? String(localized: "Connected through the server"), true)
        case .away: (String(localized: "Away"), false)
        }
    }

    /// A device that linked since `before` (the ones there when the code came up).
    static func newcomer(_ peers: [DeviceLink.Peer], before: Set<UUID>) -> String? {
        peers.first { !before.contains($0.id) }?.name
    }
}

/// Reading another device's code: what is typed, pasted or seen, and how far the link got. A value, so
/// the sheet only shows it (tested in `ImpTests`).
struct LinkJoin: Equatable {
    var text = ""
    private(set) var joining = false
    private(set) var linked: String?
    private(set) var error: String?

    enum Status: Equatable {
        case empty, notALink, ready, joining
        case linked(String)
        case failed(String)
    }

    var invite: LinkInvite? { LinkInvite(string: text) }

    var status: Status {
        if let linked { return .linked(linked) }
        if joining { return .joining }
        if let error { return .failed(error) }
        if text.isEmpty { return .empty }
        return invite == nil ? .notALink : .ready
    }

    /// Link is offered for a code from Imp, once, and not while linking.
    var canLink: Bool { invite != nil && !joining && linked == nil }
    /// Nothing more can be typed or pasted while linking or once linked.
    var isLocked: Bool { joining || linked != nil }

    /// A code the camera saw: only an Imp code counts, and only while nothing else is going on. Returns
    /// the invite to link with.
    mutating func found(_ code: String) -> LinkInvite? {
        guard !isLocked, let invite = LinkInvite(string: code) else { return nil }
        text = code
        return invite
    }

    /// What was pasted: text, or the codes read off a picture. Nothing usable says so.
    mutating func paste(text pasted: String?, codes: [String]) {
        error = nil
        if let pasted = pasted?.trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty {
            text = pasted
        } else if let code = codes.first(where: { LinkInvite(string: $0) != nil }) {
            text = code
        } else {
            error = String(localized: "There's no Imp link or code to paste.")
        }
    }

    mutating func start() { error = nil; joining = true }
    mutating func finish(linked name: String) { joining = false; linked = name }
    mutating func finish(failed message: String) { joining = false; error = message }
}

/// Link a device: one sheet, two ways. Show this Mac's code for the other device's camera (with its link to
/// copy), or read the other device's code with this Mac's camera (or paste its link, or a picture of it).
/// The tabs switch between them; the steps under the code say what to do on the other device.
struct LinkDeviceSheet: View {
    enum Mode: String, Identifiable, CaseIterable {
        case show, scan
        var id: String { rawValue }
        var title: String { String(localized: self == .show ? "devices.show" : "devices.scan") }
        var symbol: String { self == .show ? "qrcode" : "qrcode.viewfinder" }
    }

    let model: AppModel
    @State var mode: Mode
    /// Shown instead of this Mac's own code (design renders: nothing is listened for).
    var preview: LinkInvite?
    @State private var invite: LinkInvite?
    @State private var copied = false
    @State private var before: Set<UUID> = []
    @State private var scanner = CodeScanner()
    @State private var join = LinkJoin()

    init(model: AppModel, mode: Mode, preview: LinkInvite? = nil) {
        self.model = model
        _mode = State(initialValue: mode)
        self.preview = preview
    }

    private var newcomer: String? { LinkedDevices.newcomer(model.link.peers, before: before) }

    var body: some View {
        SheetScaffold(icon: mode.symbol, title: "settings.devices.pair.title",
                      info: "The code holds a key only this Mac and the scanning device share. What they say is encrypted.") {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                SegmentedTabs(tabs: Mode.allCases, selection: $mode, title: \.title, icon: \.symbol)
                Group {
                    switch mode {
                    case .show: showCode
                    case .scan: scanCode
                    }
                }
                .padding(Spacing.large)
                .frame(maxWidth: .infinity)
                .impCard(radius: Radius.medium)
            }
        } footer: {
            switch mode {
            case .show:
                Button { copyLink() } label: { FitLabel(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") }
                    .buttonStyle(.imp(.secondary))
                    .disabled(invite == nil)
                    .help(Text("devices.copy_link.help"))
                Spacer()
            case .scan:
                Button { paste() } label: { FitLabel("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.imp(.secondary))
                    .disabled(join.isLocked)
                    .help("Pastes a link, or a picture of a code")
                Spacer()
                if join.linked == nil {
                    Button { join.invite.map(link) } label: { FitLabel("Link", systemImage: "link") }
                        .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                        .disabled(!join.canLink)
                }
            }
        }
        .onAppear {
            before = Set(model.link.peers.map(\.id))
            invite = preview ?? model.link.invite()
        }
        .onDisappear {
            scanner.stop()
            if preview == nil { model.link.inviteHidden() }
        }
        .task(id: mode) {
            if mode == .scan, preview == nil { await scanner.start { found($0) } } else { scanner.stop() }
        }
    }

    // MARK: Show this Mac's code

    private var showCode: some View {
        VStack(spacing: Spacing.large) {
            Group {
                if let image = invite.flatMap({ QRCode.image(for: $0.url.absoluteString) }) {
                    // Dark squares on white, never tinted: the picture carries its own quiet zone,
                    // and the white backing keeps it readable on the dark appearance too.
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .blendMode(.multiply)       // the picture's white takes the backing's paper tone
                        .padding(Spacing.cozy)
                        .background(Tone.paper, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                        .accessibilityElement()
                        .accessibilityLabel("Linking code")
                } else {
                    ProgressView()
                }
            }
            .frame(width: Sizing.codeSide, height: Sizing.codeSide)
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                step(1, icon: "iphone.gen3", "**Open** Imp on your other device")
                step(2, icon: "qrcode.viewfinder", "**Scan** this code, or paste its link")
                step(3, icon: "hand.draw.fill", "**Throw** an Imp off your screen")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let newcomer {
                    StatusText(verbatim: String(localized: "\(newcomer) is linked."), symbol: "checkmark.circle.fill", color: Tone.good)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                } else {
                    HStack(spacing: Spacing.snug) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your other device…").font(Typeface.small).foregroundStyle(Tone.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .impAnimation(ImpDesign.Motion.smooth, value: newcomer)
        }
    }

    /// One step on one line: its number, an icon bead and a short phrase with the key word in bold.
    private func step(_ n: Int, icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: Spacing.small) {
            Text(verbatim: "\(n)")
                .font(Typeface.label.monospacedDigit())
                .foregroundStyle(Tone.muted)
            IconTile(systemName: icon)
            Text(text)
                .font(Typeface.body)
                .foregroundStyle(Tone.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func copyLink() {
        guard let invite else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
        copied = true
    }

    // MARK: Read another device's code

    private var scanCode: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            viewfinder
            TextField(String("implink://join?…"), text: $join.text)
                .impField(mono: true).autocorrectionDisabled()
                .disabled(join.isLocked)
            switch join.status {
            case .empty, .ready: EmptyView()
            case .linked(let name):
                StatusText(verbatim: String(localized: "Linked with \(name)."), symbol: "checkmark.circle.fill", color: Tone.good)
            case .failed(let message):
                StatusText(verbatim: message, symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
            case .notALink:
                StatusText(text: "That isn't a link from Imp.", symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
            case .joining:
                HStack(spacing: Spacing.snug) {
                    ProgressView().controlSize(.small)
                    Text("Linking…").font(Typeface.small).foregroundStyle(Tone.muted)
                }
            }
        }
    }

    /// The camera, with a frame to aim the code at, or why there's no picture.
    private var viewfinder: some View {
        ZStack {
            Tone.well
            switch scanner.state {
            case .starting:
                ProgressView().controlSize(.small)
            case .scanning:
                CameraPreview(session: scanner.session)
                RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                    .strokeBorder(join.linked != nil ? Tone.good : Tone.accentBright,
                                  style: StrokeStyle(lineWidth: Stroke.focus + Stroke.hairline, dash: [Spacing.wide, Spacing.medium]))
                    .frame(width: Sizing.viewfinderAim, height: Sizing.viewfinderAim)
                    .accessibilityHidden(true)
            case .denied:
                VStack(spacing: Spacing.cozy) {
                    Text("Imp may not use the camera.").font(Typeface.body).foregroundStyle(Tone.text)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(CodeScanner.privacySettings) }
                        .buttonStyle(.imp(.secondary, small: true))
                }
            case .noCamera:
                Text("This Mac has no camera. Paste the link instead.").font(Typeface.body).foregroundStyle(Tone.text)
            }
        }
        .frame(height: Sizing.viewfinderHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera")
    }

    /// A code the camera saw: an Imp code links at once, anything else is ignored.
    private func found(_ code: String) {
        if let invite = join.found(code) { link(invite) }
    }

    private func paste() {
        let pasteboard = NSPasteboard.general
        let picture = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        join.paste(text: pasteboard.string(forType: .string), codes: picture.map(CodeScanner.codes(in:)) ?? [])
    }

    private func link(_ invite: LinkInvite) {
        join.start()
        Task {
            do { join.finish(linked: try await model.link.join(invite).name) } catch { join.finish(failed: DeviceLink.message(error)) }
        }
    }
}
