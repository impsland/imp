import Foundation
import ImpCore
import Testing
@testable import ImpKit

@Suite struct EdgeDwellTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func dwell() -> EdgeDwell { EdgeDwell(delay: 0.5, maxSpeed: 250) }

    @Test func showsOnlyAfterTheDelay() {
        var d = dwell()
        d.carry(near: .left, speed: 0, at: t0)
        #expect(d.shown(at: t0.addingTimeInterval(0.4)) == nil)
        #expect(d.shown(at: t0.addingTimeInterval(0.5)) == .left)
    }

    @Test func aFlickNeverShowsIt() {
        var d = dwell()
        d.carry(near: .right, speed: 900, at: t0)
        #expect(d.shown(at: t0.addingTimeInterval(2)) == nil)
    }

    @Test func arrivingAtSpeedThenHoldingStillStartsTheWaitWhenItSlows() {
        var d = dwell()
        d.carry(near: .right, speed: 900, at: t0)
        d.carry(near: .right, speed: 0, at: t0.addingTimeInterval(1))
        #expect(d.shown(at: t0.addingTimeInterval(1.4)) == nil)
        #expect(d.shown(at: t0.addingTimeInterval(1.5)) == .right)
    }

    @Test func speedWhileWaitingStartsTheWaitOver() {
        var d = dwell()
        d.carry(near: .left, speed: 0, at: t0)
        d.carry(near: .left, speed: 600, at: t0.addingTimeInterval(0.3))
        #expect(d.shown(at: t0.addingTimeInterval(0.6)) == nil)
    }

    @Test func staysShownWhileItWaitsAndGoesWhenItLeaves() {
        var d = dwell()
        d.carry(near: .left, speed: 0, at: t0)
        d.carry(near: .left, speed: 10, at: t0.addingTimeInterval(0.6))
        #expect(d.shown(at: t0.addingTimeInterval(0.6)) == .left)
        d.carry(near: nil, speed: 0, at: t0.addingTimeInterval(0.7))
        #expect(d.shown(at: t0.addingTimeInterval(0.7)) == nil)
        d.carry(near: .left, speed: 0, at: t0.addingTimeInterval(0.8))
        #expect(d.shown(at: t0.addingTimeInterval(1.0)) == nil)
    }

    @Test func anotherSideWaitsAgain() {
        var d = dwell()
        d.carry(near: .left, speed: 0, at: t0)
        d.carry(near: .right, speed: 0, at: t0.addingTimeInterval(0.6))
        #expect(d.shown(at: t0.addingTimeInterval(0.7)) == nil)
    }

    @Test func releaseHidesIt() {
        var d = dwell()
        d.carry(near: .left, speed: 0, at: t0)
        d.release()
        #expect(d.shown(at: t0.addingTimeInterval(5)) == nil)
    }
}
