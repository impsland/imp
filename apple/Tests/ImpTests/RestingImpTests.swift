import Foundation
import Testing
@testable import Imp

/// An Imp at rest is drawn only while it blinks, and a picture that has not changed is not drawn again.
@MainActor
@Suite struct RestingImpTests {
    /// The times a resting Imp is drawn from `start`, for `seconds`.
    private func frames(from start: TimeInterval, seconds: TimeInterval, frame: TimeInterval) -> [TimeInterval] {
        var times: [TimeInterval] = [], t = start
        while t < start + seconds {
            t += Motion.blinkWait(at: t, frame: frame)
            times.append(t)
        }
        return times
    }

    @Test(arguments: [1.0 / 60, 1.0 / 30, 1.0 / 20]) func everyBlinkIsDrawnFromStartToEnd(frame: TimeInterval) {
        let start = 1_000.0, seconds = 120.0
        let drawn = frames(from: start, seconds: seconds, frame: frame)
        var blinking = 0
        for step in 0..<Int(seconds * 240) {
            let t = start + frame + Double(step) / 240
            guard Motion.blink(at: t) > 0 else { continue }
            blinking += 1
            // A frame at most one frame before any moment of a blink.
            #expect(drawn.contains { $0 <= t && t - $0 <= frame + 1e-9 }, "no frame for the blink at \(t)")
        }
        #expect(blinking > 0)
    }

    @Test func theEyesAreOpenInTheLastFrameOfABlink() {
        let frame = 1.0 / 30
        let drawn = frames(from: 2_000, seconds: 120, frame: frame)
        for (t, next) in zip(drawn, drawn.dropFirst()) where next - t > frame + 1e-9 {
            #expect(Motion.blink(at: t) == 0, "the picture waits with its eyes half shut at \(t)")
        }
    }

    @Test func aRestingImpIsDrawnForAFractionOfTheTime() {
        let frame = 1.0 / 30, seconds = 600.0
        let drawn = frames(from: 3_000, seconds: seconds, frame: frame)
        #expect(Double(drawn.count) < seconds / frame * 0.12)
    }

    @Test func aSettledFaceIsExactlyAtRest() {
        let animator = FaceAnimator()
        var target = Face(.happy)
        target.lookX = 0.4
        var face = Face()
        for step in 0..<240 { face = animator.step(to: target, at: Double(step) / 60) }
        #expect(animator.isSettled)
        #expect(face == target)
        #expect(animator.step(to: target, at: 5) == target)
    }

    @Test func onlyAPictureThatMovesByItselfChangesWithTime() {
        #expect(!ImpRenderer.changesWithTime(face: Face(.idle), motion: Motion.at(10, mood: .idle, level: 0, breathing: false), glyph: nil))
        #expect(ImpRenderer.changesWithTime(face: Face(.dizzy), motion: Motion(), glyph: nil))
        #expect(ImpRenderer.changesWithTime(face: Face(.sleepy), motion: Motion(), glyph: nil))
        #expect(ImpRenderer.changesWithTime(face: Face(.idle), motion: Motion(), glyph: .question))
        var rippling = Motion()
        rippling.ripple = 0.5
        #expect(ImpRenderer.changesWithTime(face: Face(.idle), motion: rippling, glyph: nil))
    }

    @Test func theBreathAtItsFullestIsTheDrawnOne() {
        let quarter = Double.pi / 2 / Motion.breathRate
        #expect(abs(Motion.breathDepth.bob - Motion.breath(at: quarter).bob) < 1e-9)
        #expect(Motion.breathDepth.squash > 0)
        #expect(abs(Motion.breath(at: 3 * quarter).bob + Motion.breathDepth.bob) < 1e-9)
    }
}
