import ImpKit
import Testing

@Suite struct BubbleTimeoutTests {
    @Test func aFinishedBubbleNobodyIsWithTimesOut() {
        #expect(BubbleTimeout.mayHide(finished: true, hovered: false, kept: false, playing: false))
    }

    @Test func anUnfinishedBubbleNeverTimesOut() {
        #expect(!BubbleTimeout.mayHide(finished: false, hovered: false, kept: false, playing: false))
    }

    @Test func itWaitsWhileYouHoverListenOrKeepIt() {
        #expect(!BubbleTimeout.mayHide(finished: true, hovered: true, kept: false, playing: false))
        #expect(!BubbleTimeout.mayHide(finished: true, hovered: false, kept: false, playing: true))
        #expect(!BubbleTimeout.mayHide(finished: true, hovered: false, kept: true, playing: false))
    }
}
