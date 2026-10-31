import Testing
@testable import ImpKit

/// The rules of Echo, the memory game on the phone.
@Suite struct EchoTests {
    /// Runs the clock until the player's turn (or `limit` seconds), collecting what happened.
    private func untilTurn(_ round: inout EchoRound, limit: Double = 60) -> [EchoRound.Event] {
        var events: [EchoRound.Event] = []
        var t = 0.0
        while round.phase != .repeating, !round.isOver, t < limit {
            events += round.advance(1 / 60)
            t += 1 / 60
        }
        return events
    }

    /// A round past its guided step, at the start of the real thing.
    private func started(seed: UInt64 = 7) -> EchoRound {
        var round = EchoRound(coaching: false, seed: seed)
        _ = untilTurn(&round)
        return round
    }

    private func repeatAll(_ round: inout EchoRound) -> [EchoRound.Event] {
        var events: [EchoRound.Event] = []
        for rune in round.sequence { events += round.tap(rune) }
        return events
    }

    @Test func sameSeedSameSequence() {
        var a = EchoRound(seed: 42), b = EchoRound(seed: 42)
        for _ in 0..<6 {
            _ = untilTurn(&a); _ = untilTurn(&b)
            _ = repeatAll(&a); _ = repeatAll(&b)
            #expect(a.sequence == b.sequence)
            for _ in 0..<120 { _ = a.advance(1 / 60); _ = b.advance(1 / 60) }
        }
    }

    @Test func showsEachRuneInOrderThenGivesTheTurn() {
        var round = EchoRound(coaching: false, seed: 3)
        let events = untilTurn(&round)
        let lit = events.compactMap { event -> Int? in if case .light(let rune, _) = event { rune } else { nil } }
        let hopped = events.compactMap { event -> Int? in if case .hop(let rune, _) = event { rune } else { nil } }
        #expect(lit == round.sequence)
        #expect(hopped == round.sequence)
        #expect(events.last == .yourTurn(length: 1))
        #expect(round.phase == .repeating)
    }

    @Test func aRightSequenceGrowsTheNextOne() {
        var round = started()
        let first = round.sequence
        let events = repeatAll(&round)
        #expect(events.contains { if case .cleared(let n, let points, let clean, _, _) = $0 { n == 1 && points == 2 && clean } else { false } })
        #expect(round.level == 1)
        #expect(round.sequence.count == 2)
        #expect(Array(round.sequence.prefix(1)) == first)
        _ = untilTurn(&round)
        #expect(round.phase == .repeating)
    }

    @Test func aWrongTapCostsALifeAndReplaysTheSameSequence() {
        var round = started()
        let sequence = round.sequence
        let wrong = (sequence[0] + 1) % EchoRound.runes
        let events = round.tap(wrong)
        #expect(events == [.mistake(rune: wrong, expected: sequence[0], livesLeft: EchoRound.lives - 1)])
        #expect(round.lives == EchoRound.lives - 1)
        #expect(round.phase == .between)
        _ = untilTurn(&round)
        #expect(round.sequence == sequence)
        // Cleared after a slip pays single.
        let cleared = repeatAll(&round)
        #expect(cleared.contains { if case .cleared(_, let points, let clean, _, _) = $0 { points == 1 && !clean } else { false } })
    }

    @Test func threeSlipsEndTheRound() {
        var round = started()
        var finished = false
        for _ in 0..<EchoRound.lives {
            let wrong = (round.sequence[0] + 1) % EchoRound.runes
            finished = round.tap(wrong).contains(.finished)
            _ = untilTurn(&round)
        }
        #expect(finished)
        #expect(round.isOver)
        #expect(round.tap(0).isEmpty)
    }

    @Test func tapsOutsideTheTurnAreIgnored() {
        var round = EchoRound(coaching: false, seed: 1)
        #expect(round.tap(0).isEmpty)
        #expect(round.score == 0)
        var turn = started()
        #expect(turn.tap(-1).isEmpty)
        #expect(turn.tap(EchoRound.runes).isEmpty)
    }

    @Test func aStuckPlayerGetsOneHint() {
        var round = started()
        var hints = 0
        for _ in 0..<(60 * 12) {
            for case .hint(let rune) in round.advance(1 / 60) { #expect(rune == round.sequence[0]); hints += 1 }
        }
        #expect(hints == 1)
        #expect(round.lives == EchoRound.lives)
    }

    @Test func aCleanFifthLevelWinsALifeBack() {
        var round = started(seed: 11)
        _ = round.tap((round.sequence[0] + 1) % EchoRound.runes)
        #expect(round.lives == EchoRound.lives - 1)
        // Level one is slipped; levels two to five are clean, and five wins the life back.
        _ = untilTurn(&round)
        var gained = false
        while round.level < 5 {
            for case .cleared(_, _, _, _, let life) in repeatAll(&round) { gained = gained || life }
            _ = untilTurn(&round)
        }
        #expect(gained)
        #expect(round.lives == EchoRound.lives)
    }

    @Test func noRuneThreeTimesInARow() {
        var round = started(seed: 5)
        while round.level < 14 {
            _ = repeatAll(&round)
            _ = untilTurn(&round)
        }
        let s = round.sequence
        for i in 2..<s.count { #expect(!(s[i] == s[i - 1] && s[i] == s[i - 2])) }
    }

    @Test func theGuidedStepCostsNothingThenRulesThenCountdown() {
        var round = EchoRound(coaching: true, seed: 9)
        #expect(round.isLesson)
        _ = untilTurn(&round)
        #expect(round.sequence.count == EchoRound.lessonLength)
        // A slip in the lesson costs nothing and plays it again.
        _ = round.tap((round.sequence[0] + 1) % EchoRound.runes)
        #expect(round.lives == EchoRound.lives)
        _ = untilTurn(&round)
        let events = repeatAll(&round)
        #expect(events.contains(.rules))
        #expect(round.phase == .rules)
        #expect(round.score == 0 && !round.isLesson)
        var ticks: [Int] = []
        for _ in 0..<(60 * 10) {
            for case .tick(let n) in round.advance(1 / 60) { ticks.append(n) }
        }
        #expect(ticks == [3, 2, 1, 0])
        #expect(round.phase == .watching || round.phase == .repeating)
        #expect(round.sequence.count == 1)
    }

    @Test func theGuidedStepCanBeSkipped() {
        var round = EchoRound(coaching: true, seed: 2)
        #expect(round.nextStep().contains(.countdown))
        #expect(round.phase == .countdown)
        #expect(!round.isLesson)
        #expect(round.nextStep().isEmpty)
    }

    @Test func theLongestSequenceWinsTheRound() {
        var round = started(seed: 21)
        var finished = false
        while !round.isOver {
            finished = repeatAll(&round).contains(.finished)
            _ = untilTurn(&round)
        }
        #expect(finished && round.completed)
        #expect(round.level == EchoRound.longest)
        #expect(round.lives == EchoRound.lives)
    }

    @Test func stoppingEndsTheRoundWithTheScore() {
        var round = started()
        _ = repeatAll(&round)
        let score = round.score
        #expect(score > 0)
        #expect(round.stop() == [.finished])
        #expect(round.isOver && round.score == score && !round.completed)
        #expect(round.stop().isEmpty)
    }

    /// A hitch that makes one frame very long still lights every rune, in order, and gives the turn once.
    @Test func aLongFrameStillShowsTheWholeSequenceOnce() {
        var round = started(seed: 9)
        _ = repeatAll(&round)
        _ = round.advance(3)
        let events = round.advance(10)
        let lit = events.compactMap { event -> Int? in
            if case .light(let rune, _) = event { rune } else { nil }
        }
        let turns = events.filter { event -> Bool in
            if case .yourTurn = event { true } else { false }
        }
        #expect(lit == round.sequence)
        #expect(turns.count == 1)
        #expect(round.phase == .repeating)
    }

    @Test func runesFadeAfterTheyLight() {
        var round = started()
        _ = round.tap(round.sequence[0])
        #expect(round.glow.max() == 1)
        for _ in 0..<120 { _ = round.advance(1 / 60) }
        #expect(round.glow.allSatisfy { $0 == 0 })
    }
}
