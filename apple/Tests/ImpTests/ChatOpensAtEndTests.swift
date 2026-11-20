import AppKit
import ImpKit
import SwiftUI
import Testing
@testable import Imp

/// The chat opens on its newest turns: the transcript shows them at once, not a blank stretch past its end that only
/// fills in once it is scrolled up.
@MainActor @Suite struct ChatOpensAtEndTests {
    @Test func aLongChatOpensOnItsNewestTurns() async throws {
        let app = AppModel(persist: false)
        let imp = ImpModel(id: app.addImp(), app: app)
        var chat = ChatHistory(folder: nil)
        let long = String(repeating: "A reply long enough to wrap over several lines in the chat. ", count: 8)
        for i in 0..<ChatView.page {
            chat.append(ChatTurn(date: Date(timeIntervalSinceReferenceDate: 812_000_000 + Double(i) * 60), request: "Question \(i)",
                                 reply: i.isMultiple(of: 3) ? long : "Short answer \(i)."))
        }
        imp.showSample(chat)
        let layout = BubbleLayout()
        // The bubble panel shows the chat first at the size it had, then takes the chat's size once measured.
        let small = CGSize(width: 300, height: 160), size = CGSize(width: 420, height: 520)
        let host = NSHostingView(rootView: ChatView(model: imp, bubble: Bubble(phase: .chat), layout: layout))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: small), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(size)
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()

        let scroll = try #require(Self.scrollView(in: host))
        let document = try #require(scroll.documentView)
        let visible = scroll.contentView.documentVisibleRect
        // The visible part of the transcript lies within its content, at its end.
        #expect(visible.height > 0)
        #expect(visible.maxY <= document.frame.height + 1, "scrolled past the end: \(visible) in \(document.frame)")
        #expect(document.frame.height - visible.maxY < 40, "not at the newest turns: \(visible) in \(document.frame)")
        withExtendedLifetime(app) {}                       // the Imp holds its app unowned
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }
}
