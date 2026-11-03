import AppKit
import AVFoundation
import Testing
@testable import Imp

/// Scrolling over a video in a chat scrolls the chat, and never moves the video along.
@MainActor @Suite struct PlayerScrollTests {
    private final class Behind: NSResponder {
        var scrolled = 0
        override func scrollWheel(with event: NSEvent) { scrolled += 1 }
    }

    @Test func scrollingOverAVideoGoesToTheChatBehindIt() throws {
        let player = AVPlayer()
        let view = ScrollThroughPlayerView()
        view.player = player
        let behind = Behind()
        view.nextResponder = behind
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        let before = player.currentTime()
        view.scrollWheel(with: event)
        #expect(behind.scrolled == 1)
        #expect(player.currentTime() == before)
    }
}
