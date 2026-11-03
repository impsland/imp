import CoreGraphics
import Foundation
import Testing
@testable import ImpKit

@Suite struct CursorFollowTests {
    private let side = 112.0

    @Test func eyesIsTheDefaultAndOffFollowsNothing() {
        let p = ImpProfile.imp
        #expect(p.follow == .eyes)
        #expect(FollowMode.eyes.title == "Eyes")
        #expect(p.followSpeed == 1)
        #expect(!FollowMode.off.eyesFollow)
        #expect(FollowMode.eyes.eyesFollow && !FollowMode.eyes.movesBody)
        #expect(FollowMode.hop.movesBody && FollowMode.glide.movesBody)
    }

    @Test func settingsRoundTripPerImp() throws {
        var p = ImpProfile.imp
        p.follow = .glide
        p.followSpeed = 9
        #expect(p.followSpeed == FollowMath.speedRange.upperBound, "clamped")
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p))
        #expect(back.follow == .glide)
        p.follow = .off
        #expect(try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p)).follow == .off)
    }

    @Test func reduceMotionTurnsHopsAndGlidesIntoEyes() {
        #expect(FollowMode.hop.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.glide.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.eyes.effective(reduceMotion: true) == .eyes)
        #expect(FollowMode.off.effective(reduceMotion: true) == .off)
        #expect(FollowMath.moves(.glide, reduceMotion: false))
        #expect(!FollowMath.moves(.glide, reduceMotion: true))
        #expect(!FollowMath.moves(.hop, reduceMotion: true))
        #expect(!FollowMath.moves(.off, reduceMotion: false))
        #expect(!FollowMath.moves(.eyes, reduceMotion: false))
    }

    @Test func itStopsShortOfTheCursor() {
        let stop = FollowMath.stopDistance(side: side)
        let target = FollowMath.target(center: CGPoint(x: 0, y: 0), cursor: CGPoint(x: 500, y: 0), side: side)
        #expect(target != nil)
        #expect(abs((target?.x ?? 0) - (500 - stop)) < 0.001)
        #expect(FollowMath.target(center: .zero, cursor: CGPoint(x: stop, y: 0), side: side) == nil, "already there")
        #expect(FollowMath.target(center: .zero, cursor: CGPoint(x: 10, y: 10), side: side) == nil, "cursor on top of it")
    }

    @Test func glideStepsTowardTheTargetAtItsSpeedAndNeverOvershoots() {
        let target = CGPoint(x: 1000, y: 0)
        let slow = FollowMath.glideStep(center: .zero, toward: target, side: side, speed: 0.5, dt: 0.1)
        let fast = FollowMath.glideStep(center: .zero, toward: target, side: side, speed: 2, dt: 0.1)
        #expect(slow.x > 0 && fast.x > slow.x)
        #expect(abs(fast.x / slow.x - 4) < 0.001)
        let near = FollowMath.glideStep(center: CGPoint(x: 998, y: 0), toward: target, side: side, speed: 2, dt: 1)
        #expect(near.x <= 1000)
        #expect(FollowMath.glideStep(center: target, toward: target, side: side, speed: 1, dt: 0.1) == target)
        // Walking it frame by frame arrives.
        var p = CGPoint.zero
        for _ in 0..<2000 { p = FollowMath.glideStep(center: p, toward: target, side: side, speed: 1, dt: 1 / 60) }
        #expect(hypot(p.x - target.x, p.y - target.y) < 1)
    }

    @Test func hopsCoverABodyAndABitAndLandOnTheLine() throws {
        let leg = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: 1000, y: 0), side: side, speed: 1))
        #expect(abs(leg.to.x - side * 1.3) < 0.001 && leg.to.y == 0)
        #expect(leg.center(at: 0) == leg.from)
        #expect(leg.center(at: 1) == leg.to)
        #expect(abs(leg.center(at: 0.5).y - leg.height) < 0.001, "highest half-way")
        #expect(leg.ground(at: 0.5).y == 0)
        let quick = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: 1000, y: 0), side: side, speed: 2))
        #expect(quick.duration < leg.duration && quick.pause < leg.pause)
    }

    @Test func aLastShortHopStopsAtTheStoppingDistance() throws {
        let stop = FollowMath.stopDistance(side: side)
        let leg = try #require(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: stop + 40, y: 0), side: side, speed: 1))
        #expect(abs(leg.to.x - 40) < 0.001)
        #expect(FollowMath.hopLeg(center: .zero, cursor: CGPoint(x: stop + 2, y: 0), side: side, speed: 1) == nil)
    }

    @Test func itStaysOnTheVisibleScreen() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let inside = FollowMath.keepVisible(CGPoint(x: 700, y: 400), side: side, in: screen)
        #expect(inside == CGPoint(x: 700, y: 400))
        let corner = FollowMath.keepVisible(CGPoint(x: -50, y: 2000), side: side, in: screen)
        #expect(corner == CGPoint(x: side / 2, y: screen.maxY - side / 2))
        let tiny = FollowMath.keepVisible(CGPoint(x: 0, y: 0), side: side, in: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(tiny == CGPoint(x: 25, y: 25))
    }

    @Test func speedIsClamped() {
        #expect(FollowMath.clampedSpeed(0) == 0.5)
        #expect(FollowMath.clampedSpeed(99) == 2)
        #expect(FollowMath.clampedSpeed(1.3) == 1.3)
    }
}
