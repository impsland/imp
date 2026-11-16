import ImpCore
import Testing
@testable import ImpKit

@Suite struct EdgeTickTests {
    private func tick() -> EdgeTick {
        var t = EdgeTick(distance: 40)
        _ = t.carry(near: .left, distance: 200, speed: 0)
        return t
    }

    @Test func crossingTheLineTowardsTheSideTicks() {
        var t = tick()
        let look1 = t.carry(near: .left, distance: 60, speed: 300)
        #expect(!look1)
        let look2 = t.carry(near: .left, distance: 39, speed: 300)
        #expect(look2)
    }

    @Test func leavingTheLineDoesNotTick() {
        var t = tick()
        let look3 = t.carry(near: .right, distance: 30, speed: 300)
        #expect(look3)
        let look4 = t.carry(near: .right, distance: 50, speed: -300)
        #expect(!look4)
    }

    @Test func movingBackFromTheSideNeverTicks() {
        var t = tick()
        let look5 = t.carry(near: .left, distance: 30, speed: -300)
        #expect(!look5)
        let look6 = t.carry(near: .left, distance: 20, speed: -10)
        #expect(!look6)
    }

    @Test func aSlowDriftOnTheLineTicksOnce() {
        var t = tick()
        let look7 = t.carry(near: .left, distance: 40, speed: 20)
        #expect(look7)
        let look8 = t.carry(near: .left, distance: 39, speed: 20)
        #expect(!look8)
        let look9 = t.carry(near: .left, distance: 38, speed: 20)
        #expect(!look9)
        let look10 = t.carry(near: .left, distance: 39.5, speed: 0)
        #expect(!look10)
    }

    @Test func crossingAgainAfterLeavingTicksAgain() {
        var t = tick()
        let look11 = t.carry(near: .left, distance: 30, speed: 300)
        #expect(look11)
        let look12 = t.carry(near: .left, distance: 80, speed: -300)
        #expect(!look12)
        let look13 = t.carry(near: .left, distance: 30, speed: 300)
        #expect(look13)
    }

    @Test func aStillImpOnTheLineDoesNotTick() {
        var t = tick()
        let look14 = t.carry(near: .left, distance: 30, speed: 0)
        #expect(!look14)
    }

    @Test func pickedUpOnTheLineIsSilentUntilItLeavesAndComesBack() {
        var t = EdgeTick(distance: 40)
        let look15 = t.carry(near: .left, distance: 30, speed: 50)
        #expect(!look15)
        let look16 = t.carry(near: .left, distance: 20, speed: 50)
        #expect(!look16)
        let look17 = t.carry(near: .left, distance: 90, speed: -50)
        #expect(!look17)
        let look18 = t.carry(near: .left, distance: 30, speed: 50)
        #expect(look18)
    }

    @Test func releaseStartsOver() {
        var t = tick()
        t.release()
        let look19 = t.carry(near: .left, distance: 30, speed: 50)
        #expect(!look19)
    }
}
