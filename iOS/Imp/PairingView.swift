import ImpKit
import SwiftUI
import UIKit
import VisionKit

/// First run: how to bring your first Imp over.
struct PairingView: View {
    let client: LinkClient
    @State private var scanning = false
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
            Text("Imps you toss from your Mac live here. Drag them, chat with them, throw them back.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.top, 6)

            VStack(alignment: .leading, spacing: 0) {
                step(1, icon: "macbook", "**Mac:** All Imps › App › iPhone")
                connector
                step(2, icon: "qrcode.viewfinder", "Scan the code with **Camera**")
                connector
                step(3, icon: "hand.draw.fill", "**Throw** an Imp off your Mac's screen")
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .card()
            .padding(.horizontal, 20).padding(.top, 22)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.flame)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30).padding(.top, 14)
                    .transition(.opacity)
            }
            Spacer(minLength: 16)

            VStack(spacing: 10) {
                if scannerAvailable {
                    Button { problem = nil; scanning = true } label: { Label("Scan Code", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(EmberButtonStyle())
                }
                Button { pasteLink() } label: { Label("Paste Link", systemImage: "doc.on.clipboard") }
                    .buttonStyle(EmberButtonStyle(filled: !scannerAvailable))
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .animation(.easeInOut, value: problem)
        .fullScreenCover(isPresented: $scanning) {
            ScannerScreen { code in
                if let pairing = LinkPairing(string: code) {
                    scanning = false
                    client.pair(pairing)
                } else {
                    scanning = false
                    problem = String(localized: "That code isn't a pairing code from Imp.")
                }
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
            problem = String(localized: "Copy the pairing link on your Mac first, then paste it here.")
            return
        }
        if let pairing = LinkPairing(string: string) {
            problem = nil
            client.pair(pairing)
        } else {
            problem = String(localized: "The clipboard doesn't hold a pairing link from Imp.")
        }
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
                Text("Scan the code on your Mac")
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
