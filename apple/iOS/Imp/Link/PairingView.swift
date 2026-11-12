import ImpDesign
import ImpKit
import SwiftUI
import UIKit
import VisionKit

/// First run, with nothing linked and no Imp yet: the live Imp and three ways to begin.
struct PairingView: View {
    let hub: LinkHub
    /// Starts hatching an Imp on this iPhone, for those who don't have another device at hand.
    var hatch: () -> Void
    /// Hatches the first Imp, asleep, and starts waking it with a Brain.
    var wake: () -> Void
    @State private var scanning = false
    @State private var showingCode = false
    @State private var problem: String?

    /// What the first Imp is called until its owner picks another name.
    static let firstName = "Imp"

    private let scannerAvailable = CodeScanner.isAvailable

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: Spacing.small)
                    Text(words("firstrun.asleep_bubble", Self.firstName))
                        .font(Typeface.body).foregroundStyle(Tone.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.large).padding(.vertical, Spacing.cozy)
                        .impCard()
                        .padding(.horizontal, Spacing.vast)
                    ZStack {
                        TiltImp().frame(width: Sizing.column / 4, height: Sizing.column / 4)
                    }
                    HStack(spacing: 0) {
                        Text("phone.pair.title")
                            .font(Typeface.title)
                            .foregroundStyle(Tone.text)
                            .accessibilityAddTraits(.isHeader)
                        InfoTip("phone.pair.tip")
                    }

                    VStack(spacing: Spacing.cozy) {
                        choice(LocalizedStringKey(words("firstrun.wake", Self.firstName)), detail: "firstrun.start.detail", icon: "moon.zzz.fill", action: wake)
                        choice("phone.pair.show_code", detail: "phone.pair.show_code.detail", icon: "qrcode") { showingCode = true }
                        if scannerAvailable {
                            choice("phone.pair.scan", detail: "phone.pair.scan.detail", icon: "qrcode.viewfinder") { problem = nil; scanning = true }
                        }
                        choice("phone.pair.hatch", detail: "phone.pair.hatch.detail", icon: "sparkles", action: hatch)
                    }
                    .padding(.horizontal, Spacing.wide)

                    HStack(spacing: Spacing.snug) {
                        if let problem { IssueBadge(text: problem, opensAtOnce: true) }
                        Button { problem = LinkClipboard.join(hub) } label: { FitLabel("phone.pair.paste", systemImage: "doc.on.clipboard") }
                            .buttonStyle(.quiet)
                    }
                    Spacer(minLength: Spacing.small)

                    Titled(title: "phone.pair.seen_as") {
                        NameField(hub: hub)
                    }
                    .padding(.horizontal, Spacing.wide).padding(.bottom, Spacing.large)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            // Scrolls, so the keyboard can't cover the name field on a small iPhone: the content keeps
            // its height and the field is brought into view, instead of being squeezed into what's left.
            .scrollBounceBehavior(.basedOnSize)
            .dismissesKeyboard()
            .keyboardGap()
        }
        .impAnimation(ImpDesign.Motion.smooth, value: problem)
        .impControls(tint: Tone.accent)
        .sheet(isPresented: $showingCode) { InviteSheet(hub: hub) }
        .fullScreenCover(isPresented: $scanning) { LinkScanner(hub: hub, problem: $problem, scanning: $scanning) }
    }

    /// One way to begin: an icon and what it does. The line on what happens is read by VoiceOver as the hint.
    private func choice(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.roomy) {
                IconTile(systemName: icon, filled: true, side: Sizing.sheetIcon)
                Text(title).font(Typeface.cardTitle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.icon(.medium, weight: .bold)).foregroundStyle(Tone.muted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Tone.text)
            .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.snug)
            .frame(minHeight: Sizing.hit)
            .impCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(detail))
    }
}

// MARK: - Pieces shared with the Devices sheet

/// The name other devices see for this iPhone, edited in place.
struct NameField: View {
    let hub: LinkHub
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("phone.name.field", text: $text)
            .impField()
            .focused($focused)
            .submitLabel(.done)
            .multilineTextAlignment(.center)
            .foregroundStyle(Tone.text)
            .onAppear { text = hub.name }
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    /// Keeps the new name, or the old one if the field was emptied.
    private func commit() {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !new.isEmpty, new != hub.name { hub.rename(new) }
        text = hub.name
    }
}

/// Links with the code on the clipboard.
@MainActor
enum LinkClipboard {
    /// Joins from the clipboard; what went wrong, if anything.
    static func join(_ hub: LinkHub) -> String? {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            return String(localized: "phone.pair.clipboard_empty")
        }
        return hub.join(code: string) ? nil : String(localized: "phone.pair.clipboard_bad")
    }
}

/// This iPhone's invite as a QR code and a link to share. Showing it makes a new code; once it's
/// off the screen it still works for 15 minutes.
struct InviteCode: View {
    let hub: LinkHub
    @State private var invite: LinkInvite?

    var body: some View {
        VStack(spacing: Spacing.roomy) {
            if let invite, let image = QRCode.image(for: invite.url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: Sizing.tipWidth)
                    .padding(Spacing.roomy)
                    // A QR code is read as black on white, whatever the app's colours.
                    .background(Tone.text, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    .accessibilityLabel("phone.pair.code.a11y")
                ShareLink(item: invite.url) { Label("phone.pair.share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(WideButtonStyle(filled: false))
            }
        }
        .task {
            // Showing a code is what needs the local network: asked for here, not at launch.
            await hub.useNetwork()
            invite = hub.node.invite()
        }
        .onDisappear { hub.node.inviteHidden() }
    }
}

/// The code on its own, from the first screen.
private struct InviteSheet: View {
    let hub: LinkHub

    var body: some View {
        VStack(spacing: Spacing.page) {
            Text("phone.pair.scan_this")
                .font(Typeface.cardTitle)
                .foregroundStyle(Tone.text)
                .accessibilityAddTraits(.isHeader)
            InviteCode(hub: hub)
        }
        .padding(Spacing.wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(Tone.surface)
        .impControls(tint: Tone.accent)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// The camera, reading a code from another device and linking with it. A code that isn't from Imp is
/// reported in `problem`.
struct LinkScanner: View {
    let hub: LinkHub
    @Binding var problem: String?
    @Binding var scanning: Bool

    var body: some View {
        ScannerScreen { code in
            scanning = false
            problem = hub.join(code: code) ? nil : String(localized: "phone.pair.code_bad")
        } cancel: { scanning = false }
    }
}

// MARK: - Scanning

private struct ScannerScreen: View {
    var found: (String) -> Void
    var cancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            CodeScanner(onCode: found).ignoresSafeArea()
            ScanFrame()
            HStack {
                Text("phone.pair.scan_other")
                    .font(Typeface.label)
                    .foregroundStyle(Tone.paper)
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.small)
                    .background(Tone.scrim, in: Capsule())
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.icon(.large, weight: .bold))
                        .frame(width: Sizing.hit, height: Sizing.hit).background(Tone.scrim, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tone.paper)
                .accessibilityLabel("common.close")
            }
            .padding()
        }
        .background(Tone.doorway)
        .impControls(tint: Tone.accent)
    }
}

/// Shows where to hold the code: a dashed rounded frame in the middle of the screen with the rest
/// dimmed. The frame is a share of the shorter side, so it is centred and about as big on every iPhone,
/// held upright or on its side, and it stays inside the safe area.
private struct ScanFrame: View {
    /// How far the dimming reaches past the screen's edges, so no rim shows under the bars.
    private static let bleed: CGFloat = 1000

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.68
            let hole = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2, width: side, height: side)
            let shape = RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
            ZStack {
                // The dimming reaches past the safe area, the frame does not.
                Path { path in
                    path.addRect(CGRect(x: -Self.bleed, y: -Self.bleed, width: geo.size.width + 2 * Self.bleed, height: geo.size.height + 2 * Self.bleed))
                    path.addPath(shape.path(in: hole))
                }
                .fill(Tone.deep.opacity(Opacity.dimmed), style: FillStyle(eoFill: true))
                shape.path(in: hole)
                    .stroke(Tone.accentBright, style: StrokeStyle(lineWidth: Stroke.focus + Stroke.hairline, lineCap: .round, dash: [Spacing.medium, Spacing.cozy]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// VisionKit's live QR reader.
struct CodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    /// Hosts the scanner and starts it once it's on screen (starting earlier throws).
    final class Host: UIViewController {
        let scanner: DataScannerViewController

        init(scanner: DataScannerViewController) {
            self.scanner = scanner
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(scanner.view)
            scanner.didMove(toParent: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            try? scanner.startScanning()
        }
    }

    func makeUIViewController(context: Context) -> Host {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return Host(scanner: scanner)
    }

    func updateUIViewController(_ vc: Host, context: Context) {
        context.coordinator.onCode = onCode
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in addedItems {
                if let payload = code.payloadStringValue {
                    done = true
                    dataScanner.stopScanning()
                    onCode(payload)
                    return
                }
            }
        }
    }
}
