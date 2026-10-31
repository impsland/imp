import Foundation
import Testing
@testable import ImpKit

@Suite struct LinkTalksTests {
    let me = linkDevice(1).id, a = linkDevice(2).id, b = linkDevice(3).id, c = linkDevice(4).id

    @Test func anImpCanMessageItsHomesImpsAndTheScreenItsOn() {
        let mine = [LinkStaged(imp: testImp(1), home: me), LinkStaged(imp: testImp(2), home: me)]
        let stage = [LinkStaged(imp: testImp(2), home: me), LinkStaged(imp: testImp(3), home: a), LinkStaged(imp: testImp(1), home: me)]
        let targets = LinkTalks.targets(of: testImp(1).id, mine: mine, stage: stage)
        #expect(targets.map(\.id) == [testImp(2).id, testImp(3).id])
    }

    @Test func aQuestionGoesToTheTargetsHomeOrElseThroughTheHolder() {
        // The target lives here.
        #expect(LinkTalks.first(me: me, targetHome: me, holder: a, connected: [a]) == .here)
        // Its home is connected.
        #expect(LinkTalks.first(me: me, targetHome: b, holder: a, connected: [a, b]) == .via(b))
        // Its home is not, but the asker's body is on a device that is: it answers or forwards.
        #expect(LinkTalks.first(me: me, targetHome: b, holder: a, connected: [a]) == .via(a))
        // The asker is at home: nobody to ask.
        #expect(LinkTalks.first(me: me, targetHome: b, holder: me, connected: [a]) == .unreachable)
        #expect(LinkTalks.first(me: me, targetHome: b, holder: a, connected: [c]) == .unreachable)
    }

    @Test func aDeviceAnswersWhatIsItsOwn() {
        #expect(LinkTalks.received(me: me, targetHome: me, forwarded: false, sender: a, connected: [a]) == .answer)
        #expect(LinkTalks.received(me: me, targetHome: me, forwarded: true, sender: a, connected: [a]) == .answer)
    }

    @Test func aDeviceForwardsOnceAtMostAndNeverBackToTheSender() {
        // Asked by a holder, for an Imp of b: pass it to b.
        #expect(LinkTalks.received(me: me, targetHome: b, forwarded: false, sender: a, connected: [a, b]) == .forward(to: b))
        // Already forwarded once: no second forward.
        #expect(LinkTalks.received(me: me, targetHome: b, forwarded: true, sender: a, connected: [a, b]) == .refuse)
        // The target's home isn't connected, or is the sender itself.
        #expect(LinkTalks.received(me: me, targetHome: b, forwarded: false, sender: a, connected: [a]) == .refuse)
        #expect(LinkTalks.received(me: me, targetHome: a, forwarded: false, sender: a, connected: [a]) == .refuse)
    }

    @Test func aQuestionAcrossThreeDevicesTakesTwoHopsAtMost() {
        // A (asker's home) -> C (holder of the asking Imp) -> B (target's home); A is not linked to B.
        let first = LinkTalks.first(me: a, targetHome: b, holder: c, connected: [c])
        #expect(first == .via(c))
        let second = LinkTalks.received(me: c, targetHome: b, forwarded: false, sender: a, connected: [a, b])
        #expect(second == .forward(to: b))
        // B answers (it's the target's home) and would refuse to pass it on.
        #expect(LinkTalks.received(me: b, targetHome: b, forwarded: true, sender: c, connected: [c]) == .answer)
        #expect(LinkTalks.received(me: c, targetHome: b, forwarded: true, sender: a, connected: [a, b]) == .refuse)
    }

    @Test func answersFindTheirWayBackAndOnlyFromTheRightDevice() {
        var pending = LinkTalks.Pending()
        let q = UUID()
        pending.sent(q, from: a, to: b)
        let r3318 = pending.answered(q, by: c)
        #expect(r3318 == nil)
        #expect(pending.questions[q] != nil)
        let answered = pending.answered(q, by: b)
        #expect(answered?.from == a && answered?.to == b)
        // An answer comes once.
        let r3657 = pending.answered(q, by: b)
        #expect(r3657 == nil)
        // A question of our own has no one to hand the answer to.
        pending.sent(q, from: nil, to: b)
        let r1516 = pending.answered(q, by: b)?.from
        #expect(r1516 == nil)
    }

    @Test func questionsTimeOutAfterTwoMinutes() {
        var pending = LinkTalks.Pending()
        let now = Date()
        let q = UUID()
        pending.sent(q, from: nil, to: a, now: now)
        let r8106 = pending.expired(now: now.addingTimeInterval(LinkProtocol.answerTimeout - 1)).isEmpty
        #expect(r8106)
        let r8783 = pending.expired(now: now.addingTimeInterval(LinkProtocol.answerTimeout)).map(\.id)
        #expect(r8783 == [q])
        let rest = pending.expired(now: now.addingTimeInterval(500)), late = pending.answered(q, by: a)
        #expect(rest.isEmpty && late == nil)
    }

    @Test func questionsToADeviceThatLeftFail() {
        var pending = LinkTalks.Pending()
        let q1 = UUID(), q2 = UUID()
        pending.sent(q1, from: nil, to: a)
        pending.sent(q2, from: nil, to: b)
        let r6427 = pending.lost(a).map(\.id)
        #expect(r6427 == [q1])
        #expect(pending.questions.keys.contains(q2) && !pending.questions.keys.contains(q1))
    }
}

@Suite struct LinkTransfersTests {
    let a = linkDevice(2).id, b = linkDevice(3).id

    @Test func aThrowIsAnsweredOnceByTheDeviceItWentTo() {
        var t = Transfers()
        let id = UUID(), imp = UUID()
        t.sent(id, imp: imp, to: a)
        let r7157 = t.answered(id, by: b)
        #expect(r7157 == nil)
        let out = t.answered(id, by: a)
        #expect(out?.imp == imp && out?.kind == .pass)
        let r9429 = t.answered(id, by: a)
        #expect(r9429 == nil)
        let r6993 = t.answered(UUID(), by: a)
        #expect(r6993 == nil)
    }

    @Test func noAnswerInTenSecondsIsADecline() {
        var t = Transfers()
        let now = Date()
        let id = UUID()
        t.sent(id, imp: UUID(), to: a, now: now)
        let r9817 = t.expired(now: now.addingTimeInterval(9.9)).isEmpty
        #expect(r9817)
        let r3125 = t.expired(now: now.addingTimeInterval(10)).map(\.id)
        #expect(r3125 == [id])
        // A late answer is nobody's business.
        let r9429 = t.answered(id, by: a)
        #expect(r9429 == nil)
    }

    @Test func movingInForGoodWaitsForTheOtherUser() {
        var t = Transfers()
        let now = Date()
        let id = UUID()
        t.sent(id, imp: UUID(), to: a, kind: .adopt, now: now)
        let r2920 = t.expired(now: now.addingTimeInterval(60)).isEmpty
        #expect(r2920)
        let r1763 = t.expired(now: now.addingTimeInterval(Transfers.adoptTimeout)).count
        #expect(r1763 == 1)
    }

    @Test func throwsToADeviceThatLeftAreGivenUp() {
        var t = Transfers()
        let x = UUID(), y = UUID()
        t.sent(x, imp: UUID(), to: a)
        t.sent(y, imp: UUID(), to: b)
        let r851 = t.lost(a).map(\.id)
        #expect(r851 == [x])
        #expect(t.outgoing.keys.contains(y))
    }

    @Test func aRepeatedIdIsAnsweredAgainNeverTakenTwice() {
        var t = Transfers()
        let id = UUID()
        let r1727 = t.received(id, from: a)
        #expect(r1727 == .new)
        #expect(t.isWaiting(id))
        let r5519 = t.received(id, from: a)
        #expect(r5519 == .pending)
        let r3804 = t.answer(id, .took)
        #expect(r3804)
        let again = t.answer(id, .declined(.full))
        #expect(!again)
        let r6160 = t.received(id, from: a)
        #expect(r6160 == .repeated(.took))
        #expect(!t.isWaiting(id))
    }

    @Test func declinesAreRepeatedToo() {
        var t = Transfers()
        let id = UUID()
        _ = t.received(id, from: a)
        t.answer(id, .declined(.playing))
        let r6517 = t.received(id, from: a)
        #expect(r6517 == .repeated(.declined(.playing)))
    }

    @Test func aThrowNobodyAnsweredLapsesToADecline() {
        var t = Transfers()
        let now = Date()
        let id = UUID()
        _ = t.received(id, from: a, now: now)
        let r6655 = t.lapsed(now: now.addingTimeInterval(5)).isEmpty
        #expect(r6655)
        let late = t.lapsed(now: now.addingTimeInterval(10))
        #expect(late.map(\.id) == [id] && late.first?.from == a)
        let r821 = t.received(id, from: a)
        #expect(r821 == .repeated(.declined(.timeout)))
        let r1947 = t.lapsed(now: now.addingTimeInterval(60)).isEmpty
        #expect(r1947)
    }

    @Test func onlyRecentAnswersAreRemembered() {
        var t = Transfers()
        let first = UUID()
        _ = t.received(first, from: a)
        t.answer(first, .took)
        for _ in 0..<Transfers.remembered { _ = t.received(UUID(), from: a) }
        let r7470 = t.received(first, from: a)
        #expect(r7470 == .new)
    }
}
