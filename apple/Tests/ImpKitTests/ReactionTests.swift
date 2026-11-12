import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

@Suite struct MouseGestureTests {
    let center = CGPoint(x: 500, y: 300), r: CGFloat = 50

    /// Feeds a path sampled at 60 Hz; returns the first gesture (and when it came).
    private func first(_ g: inout MouseGestures, frames: Int, from start: Int = 0,
                       _ path: (Int) -> CGPoint) -> (AnimationTrigger, Double)? {
        for i in start..<(start + frames) {
            let t = Double(i) / 60
            if let found = g.move(to: path(i), at: t, center: center, radius: r) { return (found, t) }
        }
        return nil
    }

    @Test func circlingMakesImpDizzy() {
        var g = MouseGestures()
        let found = first(&g, frames: 200) { i in
            let a = Double(i) * 0.12
            return CGPoint(x: center.x + 120 * cos(a), y: center.y + 120 * sin(a))
        }
        #expect(found?.0 == .circle)
    }

    @Test func swishingInFrontIsAWave() {
        var g = MouseGestures()
        let found = first(&g, frames: 120) { i in CGPoint(x: center.x + 90 * sin(Double(i) * 0.2), y: center.y + 30) }
        #expect(found?.0 == .swish)
    }

    @Test func gentleStrokesOnTheHeadArePetting() {
        var g = MouseGestures()
        let found = first(&g, frames: 240) { i in CGPoint(x: center.x + 30 * sin(Double(i) * 0.12), y: center.y + 25) }
        #expect(found?.0 == .stroke)
        #expect((found?.1 ?? 0) > 0.7, "it takes a few unhurried strokes")
    }

    @Test func pettingGoesOnWhileTheStrokesDo() {
        var g = MouseGestures()
        var strokes = 0
        for i in 0..<600 {
            let p = CGPoint(x: center.x + 30 * sin(Double(i) * 0.12), y: center.y + 25)
            if g.move(to: p, at: Double(i) / 60, center: center, radius: r) == .stroke { strokes += 1 }
        }
        #expect(strokes >= 5, "each stroke after the first keeps it purring")
    }

    @Test func quickJigglesOnTheHeadTickle() {
        var g = MouseGestures()
        // Small, fast scrubs: ~3 a second, ±10 pt.
        let found = first(&g, frames: 120) { i in CGPoint(x: center.x + 10 * sin(Double(i) * 0.33), y: center.y + 5) }
        #expect(found?.0 == .tickle)
    }

    @Test func headingForImpToDragItIsNothing() {
        var g = MouseGestures()
        // Glide in from the side, slow down and settle on the head with a little hand tremor.
        for i in 0..<90 {
            let k = min(1, Double(i) / 60)
            let ease = 1 - pow(1 - k, 3)
            let p = CGPoint(x: center.x - 400 * (1 - ease) + sin(Double(i)) * 1.5, y: center.y + 10 + cos(Double(i) * 1.3) * 1.5)
            #expect(g.move(to: p, at: Double(i) / 60, center: center, radius: r) == nil)
        }
    }

    @Test func aPressSilencesGesturesUntilTheCursorLeaves() {
        var g = MouseGestures()
        _ = g.move(to: CGPoint(x: center.x, y: center.y + 10), at: 0, center: center, radius: r)
        g.pressed()
        // Strokes right after a click or drag don't count…
        let early = first(&g, frames: 240, from: 1) { i in CGPoint(x: center.x + 30 * sin(Double(i) * 0.12), y: center.y + 25) }
        #expect(early == nil)
        #expect(g.rest(at: 10, center: center, radius: r) == nil, "nor does the cursor left on its face")
        // …until the cursor has been away and comes back.
        _ = g.move(to: CGPoint(x: center.x + 200, y: center.y), at: 4.1, center: center, radius: r)
        let found = first(&g, frames: 240, from: 250) { i in CGPoint(x: center.x + 30 * sin(Double(i) * 0.12), y: center.y + 25) }
        #expect(found?.0 == .stroke)
    }

    @Test func restingOnTheFaceIsAStareAndBesideItALinger() {
        var g = MouseGestures()
        _ = g.move(to: CGPoint(x: center.x + 5, y: center.y), at: 0, center: center, radius: r)
        #expect(g.rest(at: 1.0, center: center, radius: r) == nil, "too soon: you may just be about to drag it")
        #expect(g.rest(at: MouseGestures.stareAfter, center: center, radius: r) == .stare)
        #expect(g.rest(at: 5, center: center, radius: r) == nil, "once per rest")

        var h = MouseGestures()
        _ = h.move(to: CGPoint(x: center.x + r * 2, y: center.y), at: 0, center: center, radius: r)
        #expect(h.rest(at: 2, center: center, radius: r) == nil)
        #expect(h.rest(at: MouseGestures.lingerAfter, center: center, radius: r) == .linger)

        var far = MouseGestures()
        _ = far.move(to: CGPoint(x: center.x + r * 6, y: center.y), at: 0, center: center, radius: r)
        #expect(far.rest(at: 10, center: center, radius: r) == nil)
    }

    @Test func rushingAtImpStartlesIt() {
        var g = MouseGestures()
        // 450 pt in 0.1 s, straight at its head.
        let found = first(&g, frames: 7) { i in CGPoint(x: center.x - 450 + Double(i) * 75, y: center.y) }
        #expect(found?.0 == .rush)
        // The same path, unhurried, is nothing.
        var slow = MouseGestures()
        let unhurried = first(&slow, frames: 91) { i in CGPoint(x: center.x - 450 + Double(i) * 5, y: center.y) }
        #expect(unhurried == nil)
    }

    @Test func bobbingAboveItsHeadDangles() {
        var g = MouseGestures()
        let found = first(&g, frames: 180) { i in CGPoint(x: center.x, y: center.y + r * 2 + 30 * sin(Double(i) * 0.15)) }
        #expect(found?.0 == .dangle)
    }

    @Test func ordinaryMovementIsNothing() {
        var g = MouseGestures()
        for i in 0..<200 {
            let p = CGPoint(x: 100 + Double(i) * 6, y: 700 - Double(i) * 2)
            #expect(g.move(to: p, at: Double(i) * 0.016, center: center, radius: r) == nil)
        }
    }
}

@Suite struct PressGestureTests {
    @Test func shakingWhileCarryingIsAShakeOnce() {
        var p = PressGestures()
        var shakes = 0
        for i in 0..<120 {
            let pt = CGPoint(x: 300 + 60 * sin(Double(i) * 0.5), y: 300)
            if p.drag(to: pt, at: Double(i) / 60) { shakes += 1 }
        }
        #expect(shakes == 1)
    }

    @Test func carryingSomewhereIsNotAShake() {
        var p = PressGestures()
        for i in 0..<120 {
            let shaken = p.drag(to: CGPoint(x: 300 + Double(i) * 4, y: 300 + Double(i)), at: Double(i) / 60)
            #expect(!shaken)
        }
    }
}

@Suite struct OscillationTests {
    @Test func turnsCountOnlyAfterAFullSwing() {
        var o = Oscillation(window: 10)
        for (i, x) in [0.0, 5, 10, 25, 20, 30, 10, -5, 5, 12].enumerated() {
            o.add(x, at: Double(i), minSwing: 10)
        }
        // Turns at 30 → 10 and at -5 → 5/12 (the 25 → 20 → 30 wobble is too small).
        #expect(o.count == 2)
        #expect(o.span(ofLast: 2) == 2)
        #expect(o.span(ofLast: 3) == nil)
    }
}
