import AppKit
import SwiftUI
import Testing
import ImpKit
@testable import Imp

/// The app's own paths that once stopped it: an Imp working on another device, and video in a reply.
@MainActor @Suite struct CrashTests {
    /// An Imp that lives on the iPhone reports each tool it uses. Its body on the Mac closes the last
    /// step and adds the new one: that once changed and read the work in the same breath and crashed.
    @Test func workFromAnotherDeviceMovesThroughItsSteps() throws {
        let app = AppModel(persist: false)
        let imp = ImpModel(id: UUID(), app: app)
        imp.heard(work: LinkWork(request: "Wave at me", status: nil, partial: ""))
        imp.heard(work: LinkWork(request: "Wave at me", status: "play animation", partial: ""))
        imp.heard(work: LinkWork(request: "Wave at me", status: "write a note", partial: "Done"))
        let work = try #require(imp.work)
        #expect(work.steps.map(\.title) == ["play animation", "write a note"])
        #expect(work.steps.first?.state == .done)
    }

    @Test func aVideoThatIsThereGetsAPlayer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString).mp4")
        try Data(repeating: 0, count: 64).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let media = Media(url: file, kind: .video, slot: nil)
        #expect(!media.missing)
        render(MediaView(url: file, title: "Clip", kind: .video, owner: nil, autoplay: false))
        media.stop()
    }

    @Test func aMissingVideoSaysSoInsteadOfCrashing() {
        let file = URL(fileURLWithPath: "/nonexistent/imp-\(UUID().uuidString).mov")
        let media = Media(url: file, kind: .video, slot: nil)
        #expect(media.missing)
        #expect(media.failed)
        render(MediaView(url: file, title: "Clip", kind: .video, owner: nil, autoplay: false))
    }

    @Test func aMissingSoundSaysSoInsteadOfCrashing() {
        let file = URL(fileURLWithPath: "/nonexistent/imp-\(UUID().uuidString).m4a")
        let media = Media(url: file, kind: .audio, slot: nil)
        #expect(media.failed)
        render(MediaView(url: file, title: "Song", kind: .audio, owner: nil, autoplay: false))
    }

    /// Lays the view out in a window, as the bubble does.
    private func render(_ view: some View) {
        let host = NSHostingView(rootView: view.frame(width: 320))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        window.close()
    }
}
