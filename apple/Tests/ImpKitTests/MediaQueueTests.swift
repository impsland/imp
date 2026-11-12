import Testing
@testable import ImpKit

@Suite struct MediaQueueTests {
    typealias Item = MediaQueue<String>.Item
    private func item(_ owner: String, _ order: Int) -> Item { Item(id: "\(owner)\(order)", owner: owner, order: order) }

    @Test func anAnswersAutoplaysTakeTurnsInOrder() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        let (a0, a1, a2) = (item("a", 0), item("a", 1), item("a", 2))
        now = q.autoplay(a0, busy: nil); #expect(now)
        // They turn up out of order while the first still plays: they wait, first in the answer first.
        now = q.autoplay(a2, busy: a0); #expect(!now)
        now = q.autoplay(a1, busy: a0); #expect(!now)
        #expect(q.waiting.map(\.id) == ["a1", "a2"])
        next = q.finished(a0); #expect(next == a1)
        next = q.finished(a1); #expect(next == a2)
        next = q.finished(a2); #expect(next == nil)
    }

    @Test func oneThatTurnsUpWhenTheLastHasEndedStartsAtOnce() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        now = q.autoplay(item("a", 0), busy: nil); #expect(now)
        next = q.finished(item("a", 0)); #expect(next == nil)
        now = q.autoplay(item("a", 1), busy: nil); #expect(now)       // streamed in after the first ended
    }

    @Test func aNewerAnswerTakesOver() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        now = q.autoplay(item("a", 0), busy: nil); #expect(now)
        now = q.autoplay(item("a", 1), busy: item("a", 0)); #expect(!now)
        now = q.autoplay(item("b", 0), busy: item("a", 0)); #expect(now)
        #expect(q.waiting.isEmpty)
        next = q.finished(item("a", 0)); #expect(next == nil)            // the old answer's turns are over
    }

    @Test func startingSomethingYourselfElsewhereEndsTheTurns() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        now = q.autoplay(item("a", 0), busy: nil); #expect(now)
        now = q.autoplay(item("a", 1), busy: item("a", 0)); #expect(!now)
        q.started(item("old", 3))
        next = q.finished(item("a", 0)); #expect(next == nil)
        // A history player (no answer) does the same.
        now = q.autoplay(item("b", 0), busy: nil); #expect(now)
        now = q.autoplay(item("b", 1), busy: item("b", 0)); #expect(!now)
        q.started(nil)
        #expect(q.waiting.isEmpty)
    }

    @Test func jumpingAheadInTheSameAnswerSkipsWhatsBehind() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        now = q.autoplay(item("a", 0), busy: nil); #expect(now)
        now = q.autoplay(item("a", 1), busy: item("a", 0)); #expect(!now)
        now = q.autoplay(item("a", 2), busy: item("a", 0)); #expect(!now)
        now = q.autoplay(item("a", 3), busy: item("a", 0)); #expect(!now)
        q.started(item("a", 2))                              // you play the third yourself
        next = q.finished(item("a", 2)); #expect(next == item("a", 3))
        #expect(q.waiting.isEmpty)
    }

    @Test func goneOrRepeatedOnesDontWait() {
        var q = MediaQueue<String>()
        var now = false
        var next: Item?
        now = q.autoplay(item("a", 0), busy: nil); #expect(now)
        now = q.autoplay(item("a", 1), busy: item("a", 0)); #expect(!now)
        now = q.autoplay(item("a", 1), busy: item("a", 0)); #expect(!now)
        #expect(q.waiting.count == 1)
        q.remove("a1")
        next = q.finished(item("a", 0)); #expect(next == nil)
    }
}
