import CoreImage.CIFilterBuiltins
import ImpKit
import SwiftUI
import UIKit
import VisionKit

/// First run: how to bring your first Imp over, and how to link another device.
struct PairingView: View {
    let hub: LinkHub
    /// Starts hatching an Imp on this iPhone, for those who don't have a Mac at hand.
    var hatch: (() -> Void)?
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
            Text("Imps you throw from your other devices land here. Drag them, chat with them, throw them back.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                step(1, icon: "qrcode", "**Show** a code on one device")
                connector
                step(2, icon: "qrcode.viewfinder", "**Scan** it with the other")
                connector
                step(3, icon: "hand.draw.fill", "**Throw** an Imp off the side of a screen")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .card()
            .padding(.horizontal, 20).padding(.top, 22)

            if let problem {
                // Just caused (a bad scan or paste): its words open at once, then fold into the icon.
                IssueBadge(text: problem, opensAtOnce: true)
                    .padding(.top, 10)
            }
            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button { showingCode = true } label: { Label("Show My Code", systemImage: "qrcode") }
                    .buttonStyle(EmberButtonStyle(filled: false))
                if scannerAvailable {
                    Button { problem = nil; scanning = true } label: { Label("Scan Code", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(EmberButtonStyle())
                }
                Button { pasteLink() } label: { Label("Paste Link", systemImage: "doc.on.clipboard") }
                    .buttonStyle(EmberButtonStyle(filled: !scannerAvailable))
                if let hatch {
                    Button("Or hatch an Imp on this iPhone", action: hatch)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Dungeon.muted)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .animation(.easeInOut, value: problem)
        .sheet(isPresented: $showingCode) { InviteSheet(hub: hub) }
        .fullScreenCover(isPresented: $scanning) {
            ScannerScreen { code in
                scanning = false
                if !hub.join(code: code) { problem = String(localized: "That code isn't from Imp.") }
            } cancel: { scanning = false }
        }
    }

    /// One step, on one line: an icon (numbered) and a short phrase, the key word in bold.
    private func step(_ n: Int, icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Dungeon.flame)
                .frame(width: 36, height: 36)
                .background(Dungeon.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Text(verbatim: "\(n)")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(Dungeon.deep)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Dungeon.flame))
                        .offset(x: 5, y: -5)
                }
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Dungeon.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// A faint dotted line from one step's icon to the next.
    private var connector: some View {
        Rectangle()
            .fill(Dungeon.ember.opacity(0.35))
            .frame(width: 1.5, height: 10)
            .mask(VStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Capsule().frame(height: 2.5) } })
            .padding(.leading, 17.25)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
    }

    private func pasteLink() {
        guard let string = UIPasteboard.general.string, !string.isEmpty else {
            problem = String(localized: "Copy the link from the other device first, then paste it here.")
            return
        }
        if hub.join(code: string) {
            problem = nil
        } else {
            problem = String(localized: "The clipboard doesn't hold a link from Imp.")
        }
    }
}

// MARK: - Showing

/// This iPhone's invite, as a code another device scans (or a link it opens). A code works for 15
/// minutes after it was last on screen.
private struct InviteSheet: View {
    let hub: LinkHub
    @State private var invite: LinkInvite?

    var body: some View {
        VStack(spacing: 18) {
            Text("Scan this with Imp on another device")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Dungeon.cream)
            if let invite, let image = Self.code(for: invite.url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Link code")
                ShareLink(item: invite.url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    .buttonStyle(EmberButtonStyle(filled: false))
                    .padding(.horizontal, 40)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Dungeon.deep)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { invite = hub.node.invite() }
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
