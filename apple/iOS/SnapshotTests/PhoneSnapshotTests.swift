import ImpDesign
import ImpKit
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import ImpPhone

/// The iPhone's own screens in their key states, in the light and the dark appearance, on a fixed phone
/// size. The first run on a developer machine records the images next to this file (in `__Snapshots__`),
/// and later runs compare. They need the Simulator, so CI only builds them (docs/apps/testing.md).
@MainActor
@Suite("iPhone screen snapshots", .serialized)
struct PhoneSnapshotTests {
    private static let phone = ViewImageConfig.iPhone13Pro

    /// The notice at the top of a settings section, for the section's own items.
    private func attention(_ nodes: [SettingsNode], at place: AttentionDestination) -> some View {
        ScrollView { AttentionNotice(SettingsMap.attention(nodes, at: place).map { AttentionNotice.Line($0) }).padding(16) }
            .background(Tone.surface).impControls(tint: Tone.accent)
    }

    private func firstRun(_ events: (FirstRunModel) -> Void) -> some View {
        let services = FirstRunServices(find: { [] }, models: { _, _ in [] }, check: { _ in "" })
        let flow = FirstRunModel(impName: "Dot", target: .existing(UUID()), onThisComputer: false, services: services) { _, _ in }
        events(flow)
        // No Imp figure: it moves with the clock, and a still has to be the same every time.
        return FirstRunPhoneSheet(flow: flow, imp: nil, close: {}, awake: {})
    }

    private func check(_ view: some View, _ name: String) {
        for (label, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "en_US")))
            assertSnapshot(of: host, as: .image(on: Self.phone, precision: 0.99, traits: UITraitCollection(userInterfaceStyle: style)),
                           named: "\(name).\(label)", testName: name)
        }
    }

    @Test func brainsNeedAttention() {
        let nodes = [SettingsNode(id: "me", kind: .thisDevice, name: "Anna's iPhone", state: .ready, imps: ["Dot", "Bumble"], sleeping: [Sleeper(id: UUID(), name: "Dot"), Sleeper(id: UUID(), name: "Bumble")]),
                     SettingsNode(id: "brains", kind: .brains, name: "", state: .needsSetup)]
        check(attention(nodes, at: .settings(.brains)), "settings-attention-brains")
    }

    @Test func firstRunService() { check(firstRun { _ in }, "first-run-service") }

    @Test func firstRunError() { check(firstRun { $0.continueFromService() }, "first-run-error") }

    /// Three files waiting in the chat box: a sound, a file and a picture, each with its remove button.
    @Test func chatBoxWithThreeChips() {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let files = [MediaFile(data: Data(count: 4), mimeType: "audio/wav", name: "sound.wav"),
                     MediaFile(data: Data(count: 4), mimeType: "application/pdf", name: "notes.pdf"),
                     MediaFile(data: png, mimeType: "image/png", name: "photo.png")]
        check(VStack(alignment: .leading) {
            Spacer()
            AttachmentChips(files: files) { _ in }
        }
        .padding(16).background(Tone.surface).impControls(tint: Tone.accent), "chat-chips")
    }
}
