import Foundation
import Testing
@testable import ImpKit

@Suite struct BubbleSizingTests {
    let screen = CGSize(width: 1440, height: 900)

    @Test func sizeInsideTheLimitsIsKept() {
        let s = BubbleSizing.clamped(CGSize(width: 500, height: 600), visible: screen)
        #expect(s == CGSize(width: 500, height: 600))
    }

    @Test func belowTheMinimumGrowsToIt() {
        let s = BubbleSizing.clamped(CGSize(width: 10, height: -5), visible: screen)
        #expect(s == BubbleSizing.minimum)
    }

    @Test func aboveTheScreenShrinksToWhatIsVisible() {
        let s = BubbleSizing.clamped(CGSize(width: 9000, height: 9000), visible: screen)
        #expect(s.width == screen.width - BubbleSizing.reserve.width)
        #expect(s.height == screen.height - BubbleSizing.reserve.height)
    }

    @Test func aTinyScreenBeatsTheMinimum() {
        let s = BubbleSizing.clamped(CGSize(width: 100, height: 100), visible: CGSize(width: 300, height: 300))
        #expect(s.width == 244 && s.height == 228)
    }

    @Test func nonsenseFallsBackToTheDefault() {
        let s = BubbleSizing.clamped(CGSize(width: CGFloat.nan, height: CGFloat.infinity), visible: screen)
        #expect(s.width == BubbleSizing.defaultSize.width)
        #expect(s.height <= screen.height - BubbleSizing.reserve.height)
    }

    @Test func theFrameStaysOnTheVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let far = CGRect(x: 2000, y: -500, width: 400, height: 300)
        let f = BubbleSizing.onScreen(far, visible: visible, margin: 28, topLimit: 806)
        #expect(f.maxX <= visible.maxX + 28 - 4)
        #expect(f.minY >= visible.minY - 28)
        let high = BubbleSizing.onScreen(CGRect(x: 10, y: 900, width: 400, height: 300), visible: visible, margin: 28, topLimit: 806)
        #expect(high.maxY <= 806)
    }

    @Test func inputLinesAreClamped() {
        #expect(BubbleSizing.clampedLines(0) == 2)
        #expect(BubbleSizing.clampedLines(5) == 5)
        #expect(BubbleSizing.clampedLines(99) == 12)
    }

    @Test func settingsDefaultAndRoundTrip() throws {
        var prefs = ImpPreferences()
        #expect(prefs.inputMaxLines == BubbleSizing.defaultInputLines)
        #expect(prefs.chatBubbleSize == nil)
        prefs.inputMaxLines = 99
        prefs.chatBubbleSize = CGSize(width: 480, height: 640)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.inputMaxLines == 12)
        #expect(back.chatBubbleSize == CGSize(width: 480, height: 640))
        prefs.chatBubbleSize = nil
        #expect(prefs.chatBubbleSize == nil)
    }

    @Test func oldSettingsStillLoad() throws {
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(ImpPreferences()))
        #expect(back.inputMaxLines == BubbleSizing.defaultInputLines)
    }
}
