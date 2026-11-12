import Foundation
import ImpDesign
import ImpKit
import Testing
@testable import Imp

@Suite struct TickPaceTests {
    @Test func nobodyWatchingMeansNoTicks() {
        #expect(TickPace.interval([.busy, .calm], unseen: true) == nil)
        #expect(TickPace.interval([], unseen: false) == nil)
    }

    @Test func anythingMovingTicksFast() {
        #expect(TickPace.interval([.asleep, .busy], unseen: false) == TickPace.busy)
    }

    @Test func restingImpsTickSlowlyAndSleepingOnesRarely() {
        #expect(TickPace.interval([.asleep, .calm], unseen: false) == TickPace.calm)
        #expect(TickPace.interval([.asleep, .asleep], unseen: false) == TickPace.asleep)
        #expect(TickPace.asleep <= 1 && TickPace.calm > TickPace.busy)
    }
}

@MainActor @Suite struct FrameRateTests {
    /// The Mac draws the same frame rates as the phone, because both ask `FramePolicy`.
    @Test func theMacDrawsMovementAtTheFullRateAndBreathingSmoothly() {
        #expect(Energy.fullFrame == 1.0 / 60)
        let energy = Energy.shared
        let budget = FramePolicy.budget(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        #expect(energy.frame == (budget == .full ? 1.0 / 60 : 1.0 / 30))
        #expect(energy.calmFrame <= 1.0 / 20)
    }

    @Test func theDesignTokensAreTheSameNumbers() {
        #expect(Double(Behavior.framesPerSecond) == FramePolicy.framesPerSecond)
        #expect(Double(Behavior.framesPerSecondSaving) == FramePolicy.framesPerSecondSaving)
        #expect(Double(Behavior.calmFramesPerSecond) == FramePolicy.calmFramesPerSecond)
        #expect(Double(Behavior.calmFramesPerSecondSaving) == FramePolicy.calmFramesPerSecondSaving)
        #expect(Double(Behavior.sensorHz) == FramePolicy.sensorHz)
        #expect(Double(Behavior.sensorHzSaving) == FramePolicy.sensorHzSaving)
        #expect(Double(Behavior.settleSeconds) == FramePolicy.settle)
    }

    /// The mouse is read on every frame, not on the inner life's tick, so a tick at 10 Hz never limits the eyes.
    @Test func theTickIsNotWhatPacesTheEyes() {
        #expect(TickPace.busy >= 1.0 / 30, "the ticker decides routines, the frames follow the cursor")
    }
}
