import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// This Mac in one card: its name, how it is reached (the dot is The Hop: lit once it is set up, so devices can find each
/// other from anywhere) and Link, which opens the sheet that shows this Mac's code or reads another device's.
struct ThisDeviceCard: View {
    let model: AppModel
    @State private var linking: LinkDeviceSheet.Mode?

    var body: some View {
        let hop = HopServer(model.prefs.hop)
        Card("devices.this_mac", icon: "macbook", info: "devices.this.info") {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: hop == nil ? "circle" : "circle.fill").font(.icon(.small))
                    .foregroundStyle(hop == nil ? Tone.muted : Tone.good)
                    .frame(width: Sizing.mark)
                    .help(hop.map { words("servers.state_help", $0.address, String(localized: "servers.hop.title")) }
                          ?? String(localized: "servers.hop.off_note"))
                    .accessibilityElement()
                    .accessibilityLabel(Text(hop == nil ? "servers.hop.off_note" : "servers.hop.title"))
                Button { linking = .show } label: { FitLabel("settings.devices.link.title", systemImage: "link") }
                    .buttonStyle(.imp(.primary, small: true))
                    .settingAnchor(.devicesPair)
            }
        } content: {
            EmptyView()
        }
        .settingAnchor(.devicesLink)
        .sheet(item: $linking) { mode in LinkDeviceSheet(model: model, mode: mode) }
    }
}

/// The devices linked with this Mac, each its own pebble: what it is, how it is reached, which Imps are on
/// it, whether it is Mine (trusted) and the way to forget it. Forget all is an icon in the header.
struct DevicesCard: View {
    let model: AppModel
    @State private var forgetting: DeviceLink.Peer?
    @State private var forgettingEveryone = false
    @Environment(\.postNotice) private var postNotice
    private var link: DeviceLink { model.link }

    var body: some View {
        let peers = LinkedDevices.sorted(link.peers)
        Card("devices.title", icon: "laptopcomputer.and.iphone", info: "devices.list.info") {
            if !peers.isEmpty {
                HoverIconButton(systemName: "xmark.circle", help: "settings.devices.forget_all.title", tint: Tone.danger) { forgettingEveryone = true }
                    .settingAnchor(.devicesForgetAll)
            }
        } content: {
            if link.status?.localNetworkBlocked == true { LocalNetworkNotice() }
            if peers.isEmpty {
                VStack(spacing: Spacing.small) {
                    Image(systemName: "laptopcomputer.and.iphone").font(.icon(.large)).foregroundStyle(Tone.muted)
                    Text("devices.empty").font(Typeface.body).foregroundStyle(Tone.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.large)
            } else {
                VStack(spacing: Spacing.snug) {
                    ForEach(peers) { peer in peerRow(peer) }
                }
            }
        }
        .onChange(of: link.problem, initial: true) { _, problem in if let problem { postNotice(.warning(problem)) } }
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

    /// One linked device as a pebble: its icon, name and the Imps on it (coloured dots) on the leading edge.
    /// How it is reached, Mine and Forget on the trailing edge.
    private func peerRow(_ peer: DeviceLink.Peer) -> some View {
        let reach = LinkedDevices.reach(peer, hop: HopServer(model.prefs.hop))
        let hosted = model.prefs.imps.filter { peer.imps.contains($0.id) }
        return HStack(spacing: Spacing.cozy) {
            IconTile(systemName: LinkedDevices.symbol(peer.kind)).opacity(peer.isConnected ? 1 : Opacity.dimmed)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(verbatim: peer.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                if !hosted.isEmpty {
                    HStack(spacing: Spacing.snug) {
                        ForEach(hosted, id: \.id) { imp in
                            Circle().fill(Color.imp(imp.hue)).frame(width: Spacing.small, height: Spacing.small)
                                .help(imp.name).accessibilityLabel(Text(verbatim: imp.name))
                        }
                        // Works whether or not the device is around: it may never be again (its app deleted).
                        HoverIconButton(systemName: "house", help: "settings.devices.call_home") {
                            hosted.forEach { model.callHome($0.id) }
                        }
                        .padding(.vertical, -Spacing.small)
                    }
                }
            }
            Spacer(minLength: Spacing.small)
            Image(systemName: LinkedDevices.reachSymbol(peer.reach)).font(.icon(.small))
                .foregroundStyle(reach.connected ? Tone.good : Tone.muted)
                .frame(width: Sizing.mark)
                .help(reach.text)
                .accessibilityElement().accessibilityLabel(Text(verbatim: reach.text))
            Toggle("Mine", isOn: Binding(get: { peer.isTrusted }, set: { link.setTrusted(peer.id, $0) }))
                .toggleStyle(.impSwitch).fixedSize()
            InfoTip("settings.devices.mine.info")
            HoverIconButton(systemName: "xmark.circle", help: "Forget…", tint: Tone.danger) { forgetting = peer }
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

    /// The compact picture for how a device is reached: on the network, through the server, or away.
    static func reachSymbol(_ reach: DeviceLink.Peer.Reach) -> String {
        switch reach {
        case .direct: "wifi"
        case .viaServer: "arrow.triangle.swap"
        case .away: "moon.zzz.fill"
        }
    }

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

    /// Link is offered only for an Imp code, and not while a link is joining or after it has linked.
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

    /// Takes pasted text as it is, or else the first Imp code read off a picture. Sets an error when there is neither.
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
/// The tabs switch between them. The steps under the code say what to do on the other device.
struct LinkDeviceSheet: View {
    enum Mode: String, Identifiable, CaseIterable {
        case show, scan
        var id: String { rawValue }
        var title: String { String(localized: self == .show ? "devices.show" : "devices.scan") }
        var symbol: String { self == .show ? "qrcode" : "qrcode.viewfinder" }
    }

    let model: AppModel
    @State var mode: Mode
    /// For previews: shown instead of this Mac's own code, and nothing is listened for.
    var preview: LinkInvite?
    @State private var invite: LinkInvite?
    @State private var copied: ActionState = .idle
    @State private var before: Set<UUID> = []
    @State private var scanner = CodeScanner()
    @State private var join = LinkJoin()

    init(model: AppModel, mode: Mode, preview: LinkInvite? = nil) {
        self.model = model
        _mode = State(initialValue: mode)
        self.preview = preview
    }

    private var routesKey: [AnyHashable] {
        guard let status = model.link.status else { return [] }
        return [status.routes, status.running]
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
                Button { copyLink() } label: { StatefulLabel("Copy Link", symbol: "link", state: copied) }
                    .buttonStyle(.imp(.secondary))
                    .impActionState($copied)
                    .disabled(invite == nil)
                    .help(Text("devices.copy_link.help"))
            case .scan:
                Button { paste() } label: { FitLabel("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.imp(.secondary))
                    .disabled(join.isLocked)
                    .help("Pastes a link, or a picture of a code")
                if join.linked == nil {
                    Button { join.invite.map(link) } label: { FitLabel("Link", systemImage: "link") }
                        .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                        .disabled(!join.canLink)
                }
            }
        }
        .onAppear { before = Set(model.link.peers.map(\.id)) }
        // A new code whenever its routes change (started, Wi-Fi changed, Hop set or cleared). None
        // while this Mac has no way to be reached.
        .task(id: routesKey) { invite = preview ?? model.link.invite() }
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
                    // and the paper-toned backing keeps it readable in the dark appearance too.
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
            if let newcomer {
                StatusSlot(String(localized: "\(newcomer) is linked."), symbol: "checkmark.circle.fill", color: Tone.good)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if model.link.status?.localNetworkBlocked == true {
                LocalNetworkNotice()
            } else if invite == nil {
                StatusSlot(String(localized: "link.preparing"), symbol: "hourglass")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                StatusSlot(String(localized: "Waiting for your other device…"), symbol: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
        copied = .done
    }

    // MARK: Read another device's code

    private var scanCode: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            viewfinder
            TextField(String("implink://join?…"), text: $join.text)
                .impField(mono: true).autocorrectionDisabled()
                .disabled(join.isLocked)
            scanStatus
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// One line, always there, that says how the link is going.
    @ViewBuilder private var scanStatus: some View {
        switch join.status {
        case .empty, .ready: StatusSlot(nil)
        case .linked(let name):
            StatusSlot(String(localized: "Linked with \(name)."), symbol: "checkmark.circle.fill", color: Tone.good)
        case .failed(let message):
            StatusSlot(message, symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
        case .notALink:
            StatusSlot(String(localized: "That isn't a link from Imp."), symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
        case .joining:
            StatusSlot(String(localized: "Linking…"), symbol: "hourglass")
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

/// Says that Local Network is off for Imp on this Mac, with a button that opens System Settings at
/// Privacy & Security › Local Network.
struct LocalNetworkNotice: View {
    var body: some View {
        VStack(spacing: Spacing.small) {
            StatusSlot(String(localized: "link.localnet.off"), symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
            Button { NSWorkspace.shared.open(Self.settings) } label: { FitLabel("link.localnet.open_mac", systemImage: "gear") }
                .buttonStyle(.imp(.secondary, small: true))
        }
        .frame(maxWidth: .infinity)
    }

    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}
