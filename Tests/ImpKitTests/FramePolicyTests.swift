import Foundation
import Testing
@testable import ImpKit

@Suite struct FramePolicyTests {
    @Test func theBudgetFollowsPowerAndHeat() {
        #expect(FramePolicy.budget(lowPower: false, thermal: .nominal) == .full)
        #expect(FramePolicy.budget(lowPower: false, thermal: .fair) == .full)
        #expect(FramePolicy.budget(lowPower: true, thermal: .nominal) == .saving)
        #expect(FramePolicy.budget(lowPower: false, thermal: .serious) == .saving)
        #expect(FramePolicy.budget(lowPower: true, thermal: .critical) == .critical)
    }

    @Test func movingImpsGetTheDisplayRateAndCalmOnesLess() {
        #expect(FramePolicy.interval(lively: true, budget: .full) == nil)
        #expect(FramePolicy.interval(lively: false, budget: .full) == 1.0 / 30)
        for budget in [FramePolicy.Budget.full, .saving, .critical] {
            // Calm never draws more often than lively does.
            #expect((FramePolicy.interval(lively: false, budget: budget) ?? 0) >= (FramePolicy.interval(lively: true, budget: budget) ?? 0))
        }
        // Saving more only ever slows the frames down.
        for lively in [true, false] {
            let steps = [FramePolicy.Budget.full, .saving, .critical].map { FramePolicy.interval(lively: lively, budget: $0) ?? 0 }
            #expect(steps == steps.sorted())
        }
    }

    @Test func theHoldKeepsTheRateUpWhileThingsSettle() {
        var hold = LivelyHold()
        let t = Date(timeIntervalSinceReferenceDate: 1_000)
        let still = hold.lively(moving: false, at: t)
        let moving = hold.lively(moving: true, at: t)
        let settling = hold.lively(moving: false, at: t.addingTimeInterval(FramePolicy.settle - 0.01))
        let settled = hold.lively(moving: false, at: t.addingTimeInterval(FramePolicy.settle + 0.01))
        #expect(!still && moving && settling && !settled)
        hold.extend(to: t.addingTimeInterval(5))
        let extended = hold.lively(moving: false, at: t.addingTimeInterval(4))
        #expect(extended)
    }

    @Test func throwsAndShakesStillReadWhenSampledAt50Hz() {
        // The phone's motion is sampled at 50 Hz instead of 60: the same throw and shake still read.
        func run(_ pattern: (Double) -> Double) -> [JoltDetector.Event] {
            var d = JoltDetector()
            return (0..<100).compactMap { i in d.feed(x: pattern(Double(i) / 50), at: Double(i) / 50) }
        }
        #expect(run { t in t < 0.1 ? 0 : t < 0.2 ? -3 : t < 0.3 ? 2.6 : 0 } == [.thrown(.left)])
        #expect(run { t in t < 0.6 ? 3 * sin(t * 2 * .pi * 8) : 0 } == [.shaken])
    }
}
