import CoreImage.CIFilterBuiltins
import ImpKit
import SwiftUI
import UIKit
import VisionKit

/// First run, with nothing linked and no Imp yet: the live Imp and three ways to begin.
struct PairingView: View {
    let hub: LinkHub
    /// Starts hatching an Imp on this iPhone, for those who don't have another device at hand.
    var hatch: () -> Void
    @State private var scanning = false
    @State private var showingCode = false
    @State private var problem: String?

    private let scannerAvailable = CodeScanner.isAvailable

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            ZStack {
                SoftGlow(color: Dungeon.ember, opacity: 0.3).frame(width: 340, height: 340)
                TiltImp().frame(width: 176, height: 176)
            }
            Text("Imp for iPhone")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Dungeon.cream)
            Text("Hatch an Imp here, or link another device with a code and throw Imps between them.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.top, 6)

            VStack(spacing: 10) {
                choice("Show my code", detail: "Another device scans it", icon: "qrcode") { showingCode = true }
                if scannerAvailable {
                    choice("Scan a code", detail: "From Imp on another device", icon: "qrcode.viewfinder") { problem = nil; scanning = true }
                }
                choice("Hatch an Imp", detail: "Make one right here", icon: "sparkles", action: hatch)
            }
            .padding(.horizontal, 24).padding(.top, 24)

            HStack(spacing: 6) {
                if let problem { IssueBadge(text: problem, opensAtOnce: true) }
                Button { problem = LinkClipboard.join(hub) } label: { Label("Paste Link", systemImage: "doc.on.clipboard") }
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.muted)
            }
            .padding(.top, 14)
            Spacer(minLength: 16)

            VStack(spacing: 6) {
                Text("Other devices see this iPhone as")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                NameField(hub: hub)
            }
            .padding(.horizontal, 40).padding(.bottom, 24)
        }
        .animation(.easeInOut, value: problem)
        .sheet(isPresented: $showingCode) { InviteSheet(hub: hub) }
        .fullScreenCover(isPresented: $scanning) { LinkScanner(hub: hub, problem: $problem, scanning: $scanning) }
    }

    /// One way to begin: an icon, what it does and a line on what happens.
    private func choice(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Dungeon.flame)
                    .frame(width: 42, height: 42)
                    .background(Dungeon.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(.body, design: .rounded, weight: .semibold))
                    Text(detail).font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Dungeon.muted)
            }
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .card()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pieces shared with the Devices sheet

/// The name other devices see for this iPhone, edited in place.
struct NameField: View {
    let hub: LinkHub
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .submitLabel(.done)
            .multilineTextAlignment(.center)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Dungeon.card, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? Dungeon.ember.opacity(0.6) : Dungeon.cardEdge))
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
            return String(localized: "Copy the link from the other device first, then paste it here.")
        }
        return hub.join(code: string) ? nil : String(localized: "The clipboard doesn't hold a link from Imp.")
    }
}

/// This iPhone's invite as a QR code and a link to share. Showing it makes a new code; once it's
/// off the screen it still works for 15 minutes.
struct InviteCode: View {
    let hub: LinkHub
    @State private var invite: LinkInvite?

    var body: some View {
        VStack(spacing: 14) {
            if let invite, let image = Self.code(for: invite.url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Link code")
                ShareLink(item: invite.url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    .buttonStyle(EmberButtonStyle(filled: false))
                    .padding(.horizontal, 40)
            }
        }
        .task {
            // Showing a code is what needs the local network: asked for here, not at launch.
            await hub.useNetwork()
            invite = hub.node.invite()
        }
        .onDisappear { hub.node.inviteHidden() }
    }

    /// The text as a black-and-white QR code.
    private static func code(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The code on its own, from the first screen.
private struct InviteSheet: View {
    let hub: LinkHub

    var body: some View {
        VStack(spacing: 18) {
            Text("Scan this with Imp on another device")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Dungeon.cream)
            InviteCode(hub: hub)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Dungeon.deep)
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
            problem = hub.join(code: code) ? nil : String(localized: "That code isn't from Imp.")
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
            HStack {
                Text("Scan the code on the other device")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Dungeon.cream)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36).background(.black.opacity(0.5), in: Circle())
                }
                .foregroundStyle(Dungeon.cream)
                .accessibilityLabel("Close")
            }
            .padding()
        }
        .background(.black)
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
