import AppKit
import CoreImage.CIFilterBuiltins
import ImpKit
import SwiftUI

/// Settings › App › iPhone: pair a phone (a QR code), see which phones are around, forget them.
struct PhoneCard: View {
    let model: AppModel
    @State private var pairing = false
    @State private var forgetting = false
    private var link: PhoneLink { model.phone }

    var body: some View {
        Card("iPhone", icon: "iphone.gen3",
             info: "Throw an Imp hard at the left or right side of your screen and it flies onto your iPhone. It still thinks on this Mac: chat with it there, and throw it back.") {
            if link.isSetUp {
                ForEach(link.phones.sorted { $0.lastSeen > $1.lastSeen }) { phone in
                    let here = link.connected[phone.id] != nil
                    let imps = model.prefs.imps.filter { $0.awayOn == phone.id }.map(\.name)
                    Row(LocalizedStringKey(stringLiteral: phone.name),
                        info: imps.isEmpty ? nil : LocalizedStringKey(String(localized: "On it: \(ListFormatter.localizedString(byJoining: imps))"))) {
                        StatusText(text: here ? "Connected" : "Away", symbol: "circle.fill", color: here ? .green : Dungeon.muted)
                    }
                    CardDivider()
                }
                if let problem = link.problem { StatusText(verbatim: problem, symbol: "exclamationmark.triangle.fill", color: .orange) }
                Row("Another iPhone", info: "Show the code again to pair one more. Each scan lets that phone in.") {
                    HStack(spacing: 8) {
                        Button { pairing = true } label: { Label("Show Code…", systemImage: "qrcode") }
                            .buttonStyle(.imp(.secondary, small: true))
                        Button(role: .destructive) { forgetting = true } label: { Label("Forget…", systemImage: "iphone.slash") }
                            .buttonStyle(.imp(.destructive, small: true))
                    }
                }
            } else {
                Row("Pair an iPhone", info: "Shows a code to scan with your iPhone's camera. You need Imp for iPhone, on the same network as this Mac.") {
                    Button { pairing = true } label: { Label("Pair…", systemImage: "qrcode") }
                        .buttonStyle(.imp(.primary, small: true))
                }
            }
        }
        .sheet(isPresented: $pairing) { PairingSheet(model: model) }
        .confirmationDialog("Forget every iPhone?", isPresented: $forgetting, titleVisibility: .visible) {
            Button("Forget iPhones", role: .destructive) { link.forgetPhones() }
        } message: {
            Text("Imps on a phone come back to your desktop. The old code stops working; pair again with a new one.")
        }
    }
}

/// The pairing code: a QR code for the iPhone's camera, the link itself to copy, and who's connected.
private struct PairingSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: LinkPairing?
    @State private var copied = false
    @State private var before: Set<UUID> = []

    var body: some View {
        SheetScaffold(icon: "iphone.gen3", title: "Pair an iPhone",
                      info: "The code holds a secret only your phone and this Mac know. It never goes over the network: they use it to recognise each other and to encrypt everything they say.") {
            HStack(alignment: .center, spacing: 18) {
                Group {
                    if let image = pairing.flatMap({ Self.qr($0.url.absoluteString) }) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 188, height: 188)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
                .accessibilityLabel("Pairing code")
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Open Imp on your iPhone.")
                    step(2, "Scan this code with the iPhone's Camera, or tap Scan Code in Imp.")
                    step(3, "Throw an Imp hard at the side of your screen. It lands on your phone.")
                    if let newcomer {
                        StatusText(verbatim: String(localized: "\(newcomer) is connected."), symbol: "checkmark.circle.fill", color: .green)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your iPhone…").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        } footer: {
            Button {
                guard let pairing else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pairing.url.absoluteString, forType: .string)
                copied = true
            } label: { Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") }
                .buttonStyle(.imp(.secondary))
                .help("For a phone that can't scan: paste the link in Imp on the iPhone (Paste Link). Keep it private: it lets a phone in.")
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            before = Set(model.phone.connected.keys)
            pairing = model.phone.pairing()
        }
    }

    /// A phone that connected while the code was up.
    private var newcomer: String? {
        model.phone.connected.first { !before.contains($0.key) }?.value
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(n)").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.deep)
                .frame(width: 20, height: 20).background(Circle().fill(Dungeon.flame))
            Text(text).font(.system(size: 13)).foregroundStyle(Dungeon.cream).fixedSize(horizontal: false, vertical: true)
        }
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
