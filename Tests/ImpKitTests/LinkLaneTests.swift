import Testing
@testable import ImpKit

@Suite struct LinkLaneTests {
    @Test func oneRunsAFewWaitTheRestAreTurnedAway() {
        var lane = LinkLane<Int>()
        #expect(lane.submit(0) == .run)
        for n in 1...LinkLane<Int>.waiting { #expect(lane.submit(n) == .wait) }
        #expect(lane.submit(99) == .busy)
        #expect(lane.queue.count == LinkLane<Int>.waiting)
    }

    @Test func finishingStartsTheNextInOrderAndThenIdles() {
        var lane = LinkLane<Int>()
        _ = lane.submit(0); _ = lane.submit(1); _ = lane.submit(2)
        #expect(lane.finish() == 1)
        #expect(lane.finish() == 2)
        #expect(lane.finish() == nil)
        #expect(lane.isIdle)
        #expect(lane.submit(5) == .run)
    }

    @Test func clearingDropsWhatWaitsButNotWhatRuns() {
        var lane = LinkLane<Int>()
        _ = lane.submit(0); _ = lane.submit(1)
        #expect(lane.clear() == [1])
        #expect(lane.isRunning && lane.queue.isEmpty)
    }
}
