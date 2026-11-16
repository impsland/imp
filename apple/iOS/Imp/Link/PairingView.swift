import ImpDesign
import ImpKit
import SwiftUI
import UIKit
import VisionKit

/// The first screen, with nothing linked and no Imp yet. Top half: one sleeping Imp that says what it needs in its
/// own speech bubble, its name and one sentence about what it is. Bottom half, in the thumb zone: one main button
/// that wakes it (a Brain is all it needs), and the one other way to begin, linking a device that has Imps already,
/// as a card that says what it does. The parts come in one after the other, once, unless Reduce Motion is on.
struct PairingView: View {
    let hub: LinkHub
    /// Hatches the first Imp, asleep, and starts waking it with a Brain.
    var wake: () -> Void
    @State private var linking = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the first Imp is called until its owner picks another name.
    static let firstName = ImpProfile.firstName

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: Spacing.huge)
                    hero(side: min(geo.size.width * 0.44, Self.maxImp))
                        .entrance(shown, order: 0, reduceMotion: reduceMotion)
                    VStack(spacing: Spacing.small) {
                        Text("phone.start.title")
                            .font(Typeface.display).foregroundStyle(Tone.text)
                            .accessibilityAddTraits(.isHeader)
                        Text("phone.start.subtitle")
                            .font(Typeface.body).foregroundStyle(Tone.muted)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, Spacing.large).padding(.horizontal, Spacing.vast)
                    .entrance(shown, order: 1, reduceMotion: reduceMotion)
                    Spacer(minLength: Spacing.huge)
                    actions
                        .entrance(shown, order: 2, reduceMotion: reduceMotion)
                }
                .frame(maxWidth: Self.maxWidth, minHeight: geo.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .impControls(tint: Tone.accent)
        .sheet(isPresented: $linking) { LinkSheet(hub: hub) }
        .onAppear { shown = true }
    }

    /// The Imp, asleep, and what it says: the same bubble it talks in on the stage, its tail pointing at it.
    /// It leans as the phone tips, stirs at a touch and hops when tapped.
    private func hero(side: CGFloat) -> some View {
        VStack(spacing: Spacing.small) {
            Text(words("firstrun.asleep_bubble", Self.firstName))
                .font(Typeface.body).foregroundStyle(Tone.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
                // The stage's bubble, sitting on the page: raised, but no shadow (it floats over nothing).
                .background(BubbleShape(tail: 0).fill(Tone.raised))
                .padding(.horizontal, Spacing.vast)
                .accessibilityHidden(true)
            TiltImp(asleep: true)
                // Asleep, it draws its own Zs.
                .frame(width: side, height: side)
                .accessibilityLabel(Text(words("firstrun.asleep_bubble", Self.firstName)))
        }
    }

    /// The main way in, with what it needs in one line under it, then the other way in as a card.
    private var actions: some View {
        VStack(spacing: Spacing.large) {
            VStack(spacing: Spacing.small) {
                Button(action: wake) {
                    Label { Text(words("firstrun.wake", Self.firstName)) } icon: { Image(systemName: "sparkles") }
                }
                .buttonStyle(WideButtonStyle())
                .accessibilityIdentifier("start.wake")
                Text("phone.start.wake_note")
                    .font(Typeface.caption).foregroundStyle(Tone.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button { linking = true } label: {
                HStack(spacing: Spacing.cozy) {
                    IconTile(systemName: "laptopcomputer.and.iphone")
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text("phone.start.link_title").font(Typeface.label).foregroundStyle(Tone.text)
                        Text("phone.start.link_detail").font(Typeface.caption).foregroundStyle(Tone.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Spacing.small)
                    Image(systemName: "chevron.right").font(.icon(.small, weight: .semibold)).foregroundStyle(Tone.faint)
                        .accessibilityHidden(true)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Tone.card))
                .contentShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("start.link")
        }
        .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.large)
    }

    /// The biggest the Imp is drawn, and the widest the page gets (a big phone in zoomed display).
    private static let maxImp: CGFloat = 190
    private static let maxWidth: CGFloat = 480
}

private extension View {
    /// Comes in after the parts before it (`order`): a fade and a short rise, or only the fade with Reduce Motion.
    func entrance(_ shown: Bool, order: Int, reduceMotion: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Spacing.medium)
            .animation(ImpDesign.Motion.scene.animation.delay(Double(order) * 0.08), value: shown)
    }
}

/// Linking another device, from the first screen: this iPhone's code to scan with Copy, Share, Scan and
/// Paste under it, and the name the other device will see. The same cards as the Devices section.
private struct LinkSheet: View {
    let hub: LinkHub
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: Spacing.small) {
            SheetBar(close: { dismiss() }) {
                Text("settings.devices.pair.title").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .accessibilityAddTraits(.isHeader)
            }
            .sheetBarInsets()
            ScrollView {
                VStack(spacing: Spacing.medium) {
                    LinkCodeCard(hub: hub, problem: $problem, scan: { scanning = true }, showsAtOnce: true)
                    Card("phone.name.title", icon: "iphone", info: "phone.pair.seen_as") { NameField(hub: hub) }
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.small).padding(.bottom, Spacing.wide)
                .tapAwayClosesKeyboard()
            }
            .scrollBounceBehavior(.basedOnSize)
            .dismissesKeyboard()
            .keyboardGap()
        }
        .impControls(tint: Tone.accent)
        .background(Tone.surface)
        .presentationBackground(Tone.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .impNoticeHost()
        .fullScreenCover(isPresented: $scanning) { LinkScanner(hub: hub, problem: $problem, scanning: $scanning) }
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
    /// Joins from the clipboard. What went wrong, if anything.
    static func join(_ hub: LinkHub) -> String? {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            return String(localized: "phone.pair.clipboard_empty")
        }
        return hub.join(code: string) ? nil : String(localized: "phone.pair.clipboard_bad")
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
