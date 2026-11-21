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

    private let all: [FramePolicy.Activity] = [.still, .settled, .resting, .calm, .lively]
    private let budgets: [FramePolicy.Budget] = [.full, .saving, .critical]

    private func conditions(_ budget: FramePolicy.Budget) -> FramePolicy.Conditions {
        switch budget {
        case .full: FramePolicy.Conditions()
        case .saving: FramePolicy.Conditions(lowPower: true)
        case .critical: FramePolicy.Conditions(thermal: .critical)
        }
    }

    @Test func aStillPictureCostsNoFrames() {
        #expect(FramePolicy.pace(.still, FramePolicy.Conditions()) == .paused)
    }

    /// The phone got hot left open: a room of Imps that only breathed was drawn 30 times a second for
    /// ever. An Imp at rest gets frames only while it blinks, and nothing is drawn for its breath.
    @Test func anImpAtRestIsDrawnOnlyWhileItBlinks() {
        for activity in [FramePolicy.Activity.settled, .resting] {
            #expect(FramePolicy.pace(activity, FramePolicy.Conditions()) == .blinks(1.0 / 30))
            #expect(FramePolicy.pace(activity, conditions(.saving)) == .blinks(1.0 / 20))
            #expect(FramePolicy.pace(activity, conditions(.critical)) == .paused)
            #expect(FramePolicy.pace(activity, FramePolicy.Conditions(reduceMotion: true)) == .paused)
        }
    }

    @Test func aRoomLeftAloneStopsFloatingAndOnlyBlinks() {
        let full = FramePolicy.Conditions()
        #expect(!FramePolicy.breathes(.still, full))
        #expect(!FramePolicy.breathes(.settled, full))
        for activity in [FramePolicy.Activity.resting, .calm, .lively] { #expect(FramePolicy.breathes(activity, full)) }
        #expect(FramePolicy.quiet >= 30)
    }

    @Test func nothingBreathesOffScreenWhenHotOrUnderReduceMotion() {
        for c in everyCondition where !c.running || c.reduceMotion || c.thermal == .critical {
            for activity in all { #expect(!FramePolicy.breathes(activity, c)) }
        }
    }

    @Test func nothingRunsOffScreenOrInTheBackground() {
        for activity in all {
            #expect(FramePolicy.pace(activity, FramePolicy.Conditions(active: false)) == .paused)
            #expect(FramePolicy.pace(activity, FramePolicy.Conditions(visible: false)) == .paused)
        }
        #expect(FramePolicy.motionInterval(FramePolicy.Conditions(active: false), decorative: false) == nil)
        #expect(FramePolicy.motionInterval(FramePolicy.Conditions(visible: false), decorative: false) == nil)
    }

    /// The owner saw choppy eyes and head turns: a calm Imp was drawn at 12 fps, a lively one at 30 and only a
    /// finger got 60. Anything that moves gets the display's 60, and even the breathing Imp 30.
    @Test func anythingThatMovesIsDrawnAtTheDisplaysRate() {
        let full = FramePolicy.Conditions()
        #expect(FramePolicy.pace(.lively, full) == .every(1.0 / 60))
        #expect(FramePolicy.pace(.calm, full) == .every(1.0 / 30))
    }

    @Test func noTierLooksChoppy() {
        // Reduced tiers (Low Power Mode, a warm device) fall to 30 and 20, never down to 10 or 15.
        for budget in budgets {
            let c = conditions(budget)
            if let lively = FramePolicy.pace(.lively, c).interval { #expect(lively <= 1.0 / 30) }
            if let calm = FramePolicy.pace(.calm, c).interval { #expect(calm <= 1.0 / 20) }
        }
        #expect(FramePolicy.pace(.lively, conditions(.saving)) == .every(1.0 / 30))
        #expect(FramePolicy.pace(.calm, conditions(.saving)) == .every(1.0 / 20))
        #expect(FramePolicy.pace(.lively, conditions(.critical)) == .every(1.0 / 30))
    }

    @Test func nothingIsDrawnFasterThanTheDisplay() {
        // 120 Hz is not used: the motion is slow and soft, and doubling the frames would double the cost.
        for c in everyCondition {
            for activity in all { #expect((FramePolicy.pace(activity, c).interval ?? 1) >= 1.0 / 60) }
        }
    }

    @Test func savingMoreOnlySlowsFramesDown() {
        for activity in all where activity != .still {
            let steps = budgets.map { FramePolicy.pace(activity, conditions($0)).interval ?? .infinity }
            #expect(steps == steps.sorted())
        }
    }

    @Test func moreActivityNeverGetsFewerFrames() {
        for budget in budgets {
            let c = conditions(budget)
            let steps = all.map { FramePolicy.pace($0, c).interval ?? .infinity }
            #expect(steps == steps.sorted(by: >))
        }
    }

    @Test func aHotDeviceStopsTheBreathingAndTheDecorations() {
        let hot = FramePolicy.Conditions(thermal: .serious)
        #expect(!hot.decorated)
        #expect(FramePolicy.pace(.calm, hot) == .every(1.0 / 20))
        let critical = FramePolicy.Conditions(thermal: .critical)
        #expect(FramePolicy.pace(.calm, critical) == .paused)
        #expect(FramePolicy.pace(.lively, critical) == .every(1.0 / 30))
        #expect(FramePolicy.Conditions().decorated)
        #expect(!FramePolicy.Conditions(lowPower: true).decorated)
        #expect(!FramePolicy.Conditions(visible: false).decorated)
    }

    @Test func reduceMotionStopsOnlyWhatDecorates() {
        let calm = FramePolicy.Conditions(reduceMotion: true)
        #expect(!calm.decorated)
        #expect(FramePolicy.pace(.calm, calm) == .paused)
        // What a finger or the cursor drives still answers, at the full rate.
        #expect(FramePolicy.pace(.lively, calm) == .every(1.0 / 60))
        #expect(FramePolicy.motionInterval(calm, decorative: true) == nil)
        #expect(FramePolicy.motionInterval(calm, decorative: false) == 1.0 / 30)
    }

    @Test func theSensorIsReadAtMost30TimesASecond() {
        // Fast enough that the spring easing towards each reading shows no steps, and not faster than that.
        #expect(FramePolicy.motionInterval(FramePolicy.Conditions(), decorative: true) == 1.0 / 30)
        #expect(FramePolicy.motionInterval(FramePolicy.Conditions(lowPower: true), decorative: true) == 1.0 / 20)
        #expect(FramePolicy.motionInterval(FramePolicy.Conditions(thermal: .critical), decorative: false) == nil)
    }

    /// Every combination of what the device can say, for the rules that must hold in all of them.
    private var everyCondition: [FramePolicy.Conditions] {
        var result: [FramePolicy.Conditions] = []
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for active in [true, false] { for visible in [true, false] { for lowPower in [true, false] {
            for thermal in states { for reduceMotion in [true, false] {
                result.append(.init(active: active, visible: visible, lowPower: lowPower, thermal: thermal, reduceMotion: reduceMotion))
            } }
        } } }
        return result
    }

    @Test func noPictureEverRunsFasterThanItsActivityAllows() {
        for c in everyCondition {
            #expect(FramePolicy.pace(.still, c) == .paused)
            if let calm = FramePolicy.pace(.calm, c).interval { #expect(calm >= 1.0 / 30) }
            if let lively = FramePolicy.pace(.lively, c).interval { #expect(lively >= 1.0 / 60) }
            // Only the full budget gets the display's rate.
            if let lively = FramePolicy.pace(.lively, c).interval, lively < 1.0 / 30 { #expect(c.budget == .full) }
            if c.budget != .full {
                for activity in all where activity != .still {
                    #expect((FramePolicy.pace(activity, c).interval ?? .infinity) > (FramePolicy.pace(activity, .init()).interval ?? 0))
                }
            }
        }
    }

    @Test func aSceneThatIsNotActiveOrAViewThatIsHiddenPausesEveryActivity() {
        for c in everyCondition where !c.active || !c.visible {
            for activity in all { #expect(FramePolicy.pace(activity, c) == .paused) }
            #expect(FramePolicy.motionInterval(c, decorative: true) == nil)
            #expect(FramePolicy.motionInterval(c, decorative: false) == nil)
        }
    }

    @Test func reduceMotionPausesTheDecorativeMotionEverywhere() {
        for c in everyCondition where c.reduceMotion { #expect(FramePolicy.pace(.calm, c) == .paused) }
    }

    @Test func theSensorIsNeverFasterThan30HzAndOffWhenCritical() {
        for c in everyCondition {
            for decorative in [true, false] {
                let interval = FramePolicy.motionInterval(c, decorative: decorative)
                if let interval { #expect(interval >= 1.0 / 30) }
                if c.thermal == .critical { #expect(interval == nil) }
            }
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

    @Test(arguments: [20.0, 30.0]) func throwsAndShakesStillReadAtTheSensorRates(hz: Double) {
        // The sensor is read 30 times a second (20 when saving): the same throw and a shake still read.
        func run(_ pattern: (Double) -> Double) -> [JoltDetector.Event] {
            var d = JoltDetector()
            return (0..<Int(hz * 3)).compactMap { i in d.feed(x: pattern(Double(i) / hz), at: Double(i) / hz) }
        }
        #expect(run { t in t < 0.1 ? 0 : t < 0.2 ? -3 : t < 0.3 ? 2.6 : 0 } == [.thrown(.left)])
        #expect(run { t in t < 0.6 ? 3 * sin(t * 2 * .pi * 5) : 0 } == [.shaken])
    }

    @Test func theHoldOutlastsTheSpringsItWaitsFor() {
        // A face spring (stiffness 210, damping 17) is within 0.002 of its goal after about 0.75 s, a mood blend
        // takes 0.35 s: frames must not slow down before both have finished.
        #expect(FramePolicy.settle >= 1.0)
    }

    @Test func aSpringEasesTheSameAtAnyFrameRate() {
        // The same 0.4 s of a head turning towards a goal, drawn at 20, 30, 60 and 120 fps.
        func turn(fps: Double) -> Double {
            var x = 0.0, v = 0.0
            for _ in 0..<Int(0.4 * fps) { SpringStep.advance(&x, velocity: &v, to: 1, stiffness: 90, damping: 14, dt: 1 / fps) }
            return x
        }
        let reference = turn(fps: 120)
        for fps in [20.0, 30, 60] { #expect(abs(turn(fps: fps) - reference) < 0.005, "\(fps) fps") }
    }

    @Test func aSpringFedAStairCaseOfReadingsMovesInSmallStepsEveryFrame() {
        // The sensor reads 30 times a second and the target jumps with each reading. Drawn at 60 fps the
        // value must still move a little each frame, never in the sensor's steps.
        var x = 0.0, v = 0.0
        var worst = 0.0, last = 0.0
        for frame in 0..<120 {
            let goal = Double(frame / 2 + 1) * 0.02                // a new reading every other frame
            SpringStep.advance(&x, velocity: &v, to: goal, stiffness: 90, damping: 14, dt: 1 / 60)
            if frame > 10 { worst = max(worst, abs(x - last)) }
            last = x
        }
        let readingStep = 0.02
        #expect(worst < readingStep / 2 * 1.5, "a frame moved \(worst), a reading steps \(readingStep)")
        #expect(x > 0.8)
    }

    @Test func aSpringComesToRestAndStaysThere() {
        var x = 0.0, v = 0.0
        for _ in 0..<180 { SpringStep.advance(&x, velocity: &v, to: 1, stiffness: 210, damping: 17, dt: 1 / 60) }
        #expect(abs(x - 1) < SpringSettle.distance && abs(v) < SpringSettle.speed)
    }

    @Test func aLongGapIsAPauseNotAJump() {
        var x = 0.0, v = 0.0
        SpringStep.advance(&x, velocity: &v, to: 1, stiffness: 90, damping: 14, dt: 5)
        var reference = 0.0, rv = 0.0
        SpringStep.advance(&reference, velocity: &rv, to: 1, stiffness: 90, damping: 14, dt: SpringStep.longestGap)
        #expect(x == reference && x < 0.5, "five seconds of waiting count as one 0.1 s step")
        var y = 0.0, w = 0.0
        SpringStep.advance(&y, velocity: &w, to: 1, stiffness: 90, damping: 14, dt: -1)
        #expect(y == 0 && w == 0)
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
