import Foundation
import Testing
@testable import ImpKit

@Suite struct GameScoringTests {
    /// A hundred Imps bumping each other all round earn what two Imps could.
    @Test func bonkScoreDoesNotGrowWithTheCrowd() {
        func bonkScore(imps: Int, seconds: Int) -> Int {
            var payout = BonkPayout()
            var total = 0
            for _ in 0..<(seconds * 10) {
                payout.advance(0.1)
                // Every pair that meets in this tenth of a second.
                for _ in 0..<(imps * (imps - 1) / 2) { total += payout.pay(blaze: false) }
            }
            return total
        }
        let pair = bonkScore(imps: 2, seconds: 45)
        let crowd = bonkScore(imps: 100, seconds: 45)
        #expect(crowd == pair)
        #expect(crowd <= 45 * BonkPayout.points)
    }

    @Test func bonkPaysOnceAnIntervalAndDoublesInTheBlaze() {
        var payout = BonkPayout()
        do { let p = payout.pay(blaze: false); #expect(p == 3) }
        do { let p = payout.pay(blaze: false); #expect(p == 0) }
        payout.advance(BonkPayout.interval)
        do { let p = payout.pay(blaze: true); #expect(p == 6) }
    }

    @Test func bestsAreKeptPerNumberOfImps() {
        var bests = GameBests()
        do { let r = bests.record(score: 40, imps: 2); #expect(r) }
        do { let r = bests.record(score: 90, imps: 8); #expect(r) }
        #expect(bests.best(imps: 2) == 40)
        #expect(bests.best(imps: 8) == 90)
        #expect(bests.best(imps: 3) == 0)
        // 60 beats nothing for 8 Imps even though it beats the best for 2.
        do { let r = bests.record(score: 60, imps: 8); #expect(!r) }
        #expect(bests.best(imps: 8) == 90)
        do { let r = bests.record(score: 60, imps: 2); #expect(r) }
    }

    @Test func newBestNeedsToBeatTheBestForTheSameCount() {
        var bests = GameBests()
        do { let r = bests.record(score: 0, imps: 1); #expect(!r) }
        do { let r = bests.record(score: 10, imps: 1); #expect(r) }
        do { let r = bests.record(score: 10, imps: 1); #expect(!r) }
        do { let r = bests.record(score: 11, imps: 1); #expect(r) }
    }

    @Test func bestsRoundTripThroughDefaults() throws {
        let name = "GameScoringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var bests = GameBests(defaults: defaults, key: "b")
        #expect(bests == GameBests())
        bests.record(score: 5, imps: 3)
        bests.record(score: 9, imps: 100)
        bests.save(to: defaults, key: "b")
        #expect(GameBests(defaults: defaults, key: "b") == bests)
    }
}
