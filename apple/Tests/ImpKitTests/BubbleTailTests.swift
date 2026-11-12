import Testing
@testable import ImpKit

@Suite struct BubbleTailTests {
    @Test func smallAttachedBubbleHasATail() {
        #expect(BubbleTail.isShown(chat: false, expanded: false, detached: false))
    }

    @Test func readInFullChatAndMovedHaveNone() {
        #expect(!BubbleTail.isShown(chat: false, expanded: true, detached: false))
        #expect(!BubbleTail.isShown(chat: true, expanded: false, detached: false))
        #expect(!BubbleTail.isShown(chat: false, expanded: false, detached: true))
    }

    @Test func onlyARealDragDetaches() {
        #expect(BubbleTail.isUserDrag(dragging: true, placingOurselves: false))
        #expect(!BubbleTail.isUserDrag(dragging: false, placingOurselves: false))
        #expect(!BubbleTail.isUserDrag(dragging: true, placingOurselves: true))
    }
}
