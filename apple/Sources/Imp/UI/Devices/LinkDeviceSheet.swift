import AppKit
import ImpDesign
import ImpKit
import SwiftUI

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
    var width: CGFloat = Sizing.sheetWidth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// For previews: shown instead of this Mac's own code, and nothing is listened for.
    var preview: LinkInvite?
    /// For previews: the phase to show, whatever the devices do.
    var previewPhase: LinkPhase?
    @State private var invite: LinkInvite?
    @State private var copied: ActionState = .idle
    @State private var before: Set<UUID> = []
    @State private var scanner = CodeScanner()
    @State private var join = LinkJoin()
    @State private var hopOpen = false

    init(model: AppModel, mode: Mode, width: CGFloat = Sizing.sheetWidth, preview: LinkInvite? = nil, previewPhase: LinkPhase? = nil) {
        self.model = model
        _mode = State(initialValue: mode)
        self.width = width
        self.preview = preview
        self.previewPhase = previewPhase
    }

    private var routesKey: [AnyHashable] {
        guard let status = model.link.status else { return [] }
        return [status.routes, status.running]
    }

    private var newcomer: String? { LinkedDevices.newcomer(model.link.peers, before: before) }
    private var phase: LinkPhase { previewPhase ?? LinkPhase(newcomer: newcomer, join: join) }

    /// How long the reward is seen before the sheet closes.
    private static let closeDelay: Duration = .seconds(1.6)

    /// The code's square, the same in both tabs.
    private var side: CGFloat { Sizing.codeSide }

    var body: some View {
        SheetScaffold(icon: mode.symbol, title: "settings.devices.pair.title",
                      info: "The code holds a key only this Mac and the scanning device share. What they say is encrypted.", width: width) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                SegmentedTabs(tabs: Mode.allCases, selection: $mode, title: \.title, icon: \.symbol)
                ViewThatFits(in: .horizontal) {
                    columns(stacked: false)
                    columns(stacked: true)
                }
            }
        } footer: {
            switch mode {
            case .show:
                Button { copyLink() } label: { StatefulLabel("Copy link", symbol: "link", state: copied) }
                    .buttonStyle(.imp(.secondary))
                    .impActionState($copied)
                    .disabled(invite == nil || phase.linkedName != nil)
                    .help(Text("devices.copy_link.help"))
            case .scan:
                Button { join.invite.map(link) } label: { FitLabel("Link", systemImage: "link") }
                    .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                    .disabled(!join.canLink)
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
        // Linked: the reward plays where the code was, then the sheet closes by itself.
        .task(id: phase.linkedName) {
            guard phase.linkedName != nil, preview == nil else { return }
            try? await Task.sleep(for: Self.closeDelay)
            if !Task.isCancelled { dismiss() }
        }
    }

    // MARK: Layout

    /// The code or the camera on the leading side and the words or the link on the trailing side, or one over the
    /// other when the sheet is too narrow for both. Both tabs fill the same room in the same two columns, so
    /// switching tabs or a message never moves or resizes anything: under the code is the Hop, and the camera
    /// takes that room too. Beside the code are the steps, and the link's well takes their room with its Paste.
    @ViewBuilder private func columns(stacked: Bool) -> some View {
        let leading = VStack(spacing: Spacing.cozy) {
            stage
            if mode == .show { hopButton }
        }
        .frame(width: side)
        let trailing = Group {
            switch mode {
            case .show: steps
            case .scan: scanFields
            }
        }
        .frame(minWidth: side, idealWidth: side + Sizing.sheetIcon * 2, maxWidth: .infinity, alignment: .leading)
        if stacked {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                leading.frame(maxWidth: .infinity)
                trailing.frame(height: stackedRoom)
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.wide) {
                leading
                trailing.frame(maxHeight: .infinity)
            }
        }
    }

    /// The height of the words or the link when they are under the code: the same in both tabs.
    private var stackedRoom: CGFloat { side * 0.85 }

    /// The row under the code (the Hop) and beside the camera's bottom (Paste): one height, so the columns line up.
    private static let barHeight = Sizing.control - Spacing.tight

    // MARK: The code's square

    /// One panel for what is there to read or to show: the code, the camera, the reward, or why neither. In the
    /// scan tab the camera also takes the room of the Hop below the code. Its size never changes, whatever it holds.
    private var stage: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        return ZStack {
            if let name = phase.linkedName {
                LinkedReward(name: name)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            } else if mode == .show {
                codeFace
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            } else {
                viewfinder
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: mode == .show ? side : side + Spacing.cozy + Self.barHeight)
        .background(phase.linkedName == nil && mode == .show ? Tone.paper : Tone.card, in: shape)
        .clipShape(shape)
        .impAnimation(ImpDesign.Motion.pop, value: phase.linkedName)
    }

    @ViewBuilder private var codeFace: some View {
        if model.link.status?.localNetworkBlocked == true {
            LocalNetworkNotice()
        } else if let image = invite.flatMap({ QRCode.image(for: $0.url.absoluteString) }) {
            // Dark squares on white, never tinted: the picture carries its own quiet zone,
            // and the paper-toned backing keeps it readable in the dark appearance too.
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .blendMode(.multiply)       // the picture's white takes the backing's paper tone
                .padding(Spacing.cozy)
                .accessibilityElement()
                .accessibilityLabel("Linking code")
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: The Hop

    /// The Hop under the code, as a pill with its state. It opens its settings. The code carries the Hop, so a
    /// change makes a new code. Having none is fine: devices on the same network still link.
    private var hopButton: some View {
        let hop = HopServer(model.prefs.hop)
        return Button { hopOpen = true } label: {
            HStack(spacing: Spacing.small) {
                Image(systemName: hop == nil ? "circle" : "circle.fill").font(.icon(.small))
                    .foregroundStyle(hop == nil ? Tone.muted : Tone.good)
                Text(verbatim: hop.map { words("devices.hop.pill", $0.host) } ?? String(localized: "devices.hop.add"))
                    .font(Typeface.label).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.imp(.secondary, small: true))
        .frame(height: Self.barHeight)
        .help(Text("servers.hop.about"))
        .impPopover(isPresented: $hopOpen, arrowEdge: .bottom) {
            ServerCard(kind: .hop, text: Binding(get: { model.prefs.hop }, set: { model.prefs.hop = $0 }))
                .padding(Spacing.medium)
                .frame(width: Sizing.popoverWidth)
        }
    }

    // MARK: Steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            step(1, icon: "iphone.gen3", "**Open** Imp on your other device")
            step(2, icon: "qrcode.viewfinder", "**Scan** this code, or paste its link")
            step(3, icon: "hand.draw.fill", "**Throw** an Imp off your screen")
        }
        .frame(maxHeight: .infinity, alignment: .center)
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

    /// The link to paste, filling the column down to Paste (as tall as the Hop under the code). How the link is
    /// going shows inside the well's bottom edge, so the well keeps the whole column and nothing moves. Link is the
    /// sheet's main action, in the footer.
    private var scanFields: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            EditorWell(text: $join.text, codePlaceholder: "implink://join?…", mono: true, height: nil)
                .disabled(join.isLocked)
                .opacity(join.isLocked ? Opacity.disabled : 1)
                .autocorrectionDisabled()
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) { scanStatus.padding(Spacing.cozy).allowsHitTesting(false) }
            Button { paste() } label: { FitLabel("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
                .buttonStyle(.imp(.secondary, small: true))
                .frame(height: Self.barHeight)
                .disabled(join.isLocked)
                .help("Pastes a link, or a picture of a code")
        }
    }

    /// How the link is going, over the bottom of the well: it never takes room of its own, so nothing moves.
    private var scanStatus: some View {
        let problem = phase.problem
        let linking = join.status == .joining
        return ZStack(alignment: .bottomLeading) {
            if let problem {
                Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(Typeface.small).foregroundStyle(Tone.warnText).id(problem).transition(.opacity)
            } else if linking {
                Label { Text("Linking…") } icon: { Image(systemName: "hourglass") }
                    .font(Typeface.small).foregroundStyle(Tone.muted).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .animation(ImpDesign.Motion.fade.reducedAware(reduceMotion), value: problem)
        .animation(ImpDesign.Motion.fade.reducedAware(reduceMotion), value: linking)
        .accessibilityElement(children: .combine)
    }

    /// The camera, with a frame to aim the code at, or why there's no picture.
    private var viewfinder: some View {
        ZStack {
            switch scanner.state {
            case .starting:
                ProgressView().controlSize(.small)
            case .scanning:
                CameraPreview(session: scanner.session)
                DrawnLine(shape: RoundedRectangle(cornerRadius: Radius.large, style: .continuous),
                          style: StrokeStyle(lineWidth: Stroke.focus + Stroke.hairline, dash: [Spacing.wide, Spacing.medium]))
                    .fill(Tone.accentBright)
                    .frame(width: Sizing.viewfinderAim, height: Sizing.viewfinderAim)
                    .accessibilityHidden(true)
            case .denied:
                VStack(spacing: Spacing.cozy) {
                    Text("Imp may not use the camera.").font(Typeface.small).foregroundStyle(Tone.text)
                        .multilineTextAlignment(.center)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(CodeScanner.privacySettings) }
                        .buttonStyle(.imp(.secondary, small: true))
                }
                .padding(Spacing.medium)
            case .noCamera:
                Text("This Mac has no camera. Paste the link instead.").font(Typeface.small).foregroundStyle(Tone.text)
                    .multilineTextAlignment(.center).padding(Spacing.medium)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tone.well)
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

    /// Links with the code. Once linked the camera has nothing left to read: the reward plays and the sheet closes.
    private func link(_ invite: LinkInvite) {
        join.start()
        Task {
            do {
                join.finish(linked: try await model.link.join(invite).name)
            } catch {
                join.finish(failed: DeviceLink.message(error))
            }
        }
    }
}

/// What takes the code's place once a device has linked: a check mark that pops into a soft circle, and the
/// device's name. The same size as the code. With Reduce Motion it fades in instead.
private struct LinkedReward: View {
    let name: String
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: "checkmark")
                .font(.icon(.big, weight: .bold))
                .foregroundStyle(Tone.good)
                .frame(width: Sizing.codeSide / 3, height: Sizing.codeSide / 3)
                .background(Circle().fill(Tone.good.opacity(Opacity.tintFill)))
                .scaleEffect(shown || reduceMotion ? 1 : 0.4)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: shown && !reduceMotion)
            Text(verbatim: name).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                .lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(Spacing.medium)
        .opacity(shown ? 1 : 0)
        .onAppear { withImpAnimation(ImpDesign.Motion.pop, reduceMotion: reduceMotion) { shown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(name) is linked."))
    }
}
