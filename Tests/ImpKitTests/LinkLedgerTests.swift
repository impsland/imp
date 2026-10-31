import Foundation
import Testing
@testable import ImpKit

func testImp(_ n: Int) -> LinkImp {
    LinkImp(id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", n))!, name: "Imp \(n)", hue: 0.1 * Double(n), scale: 1, traits: .plain)
}

@Suite struct LinkLedgerTests {
    let imp1 = testImp(1).id
    let a = linkDevice(2).id, b = linkDevice(3).id, c = linkDevice(4).id

    @Test func passingMakesTheReceiverTheHolder() {
        var ledger = AwayLedger()
        let ticket = ledger.mint(imp1, to: a)
        #expect(ledger.holder(of: imp1) == a && ledger.isAway(imp1) && ledger.held(by: a) == [imp1])
        #expect(ledger.entry(of: imp1)?.generation == 1)
        // Only the hash of the ticket is kept.
        #expect(ledger.entry(of: imp1)?.ticket != ticket)
        #expect(LinkCrypto.matches(ticket: ticket, hash: ledger.entry(of: imp1)!.ticket))
    }

    @Test func onlyTheHolderIsAuthorised() {
        var ledger = AwayLedger()
        _ = ledger.mint(imp1, to: a)
        #expect(ledger.authorises(a, for: imp1))
        #expect(!ledger.authorises(b, for: imp1) && !ledger.authorises(a, for: UUID()))
        #expect(!AwayLedger().authorises(a, for: imp1))
    }

    @Test func aGoodClaimRotatesTheTicketAndTheNewestHolderWins() throws {
        var ledger = AwayLedger()
        let first = ledger.mint(imp1, to: a)
        guard case .granted(let second, let previous) = ledger.claim(imp1, ticket: first, by: b) else { Issue.record("refused"); return }
        #expect(previous == a && ledger.holder(of: imp1) == b && second != first)
        #expect(ledger.entry(of: imp1)?.generation == 2)
        #expect(ledger.notices == [AwayLedger.Notice(device: a, imp: imp1)])
        // The old holder is not one any more.
        #expect(!ledger.authorises(a, for: imp1))
        let r9588 = ledger.claim(imp1, ticket: first, by: a)
        #expect(r9588 == .refused)
        #expect(ledger.holder(of: imp1) == b)
    }

    @Test func twoClaimsWithOneTicketGrantOnlyTheFirst() {
        var ledger = AwayLedger()
        let ticket = ledger.mint(imp1, to: a)
        let one = ledger.claim(imp1, ticket: ticket, by: b)
        let two = ledger.claim(imp1, ticket: ticket, by: c)
        guard case .granted = one else { Issue.record("first refused"); return }
        #expect(two == .refused)
        #expect(ledger.holder(of: imp1) == b)
    }

    @Test func aStaleOrWrongTicketIsRefusedAndChangesNothing() {
        var ledger = AwayLedger()
        let ticket = ledger.mint(imp1, to: a)
        let before = ledger
        let r4961 = ledger.claim(imp1, ticket: LinkCrypto.mintTicket(), by: b)
        #expect(r4961 == .refused)
        let r6632 = ledger.claim(imp1, ticket: Data(), by: b)
        #expect(r6632 == .refused)
        let r9894 = ledger.claim(UUID(), ticket: ticket, by: b)
        #expect(r9894 == .refused)
        #expect(ledger == before)
    }

    @Test func theHolderClaimingAgainJustRotates() {
        var ledger = AwayLedger()
        let first = ledger.mint(imp1, to: a)
        guard case .granted(let second, let previous) = ledger.claim(imp1, ticket: first, by: a) else { Issue.record("refused"); return }
        #expect(previous == nil && ledger.notices.isEmpty)
        let r9588 = ledger.claim(imp1, ticket: first, by: a)
        #expect(r9588 == .refused)
        guard case .granted = ledger.claim(imp1, ticket: second, by: a) else { Issue.record("refused"); return }
    }

    @Test func passingAgainMintsANewTicketThatKillsTheOld() {
        var ledger = AwayLedger()
        let old = ledger.mint(imp1, to: a)
        let new = ledger.mint(imp1, to: b)
        #expect(ledger.holder(of: imp1) == b && ledger.entry(of: imp1)?.generation == 2)
        let r9404 = ledger.claim(imp1, ticket: old, by: a)
        #expect(r9404 == .refused)
        guard case .granted = ledger.claim(imp1, ticket: new, by: b) else { Issue.record("refused"); return }
    }

    @Test func callingHomeKillsTheTicketAndTellsTheHolderOnce() {
        var ledger = AwayLedger()
        let ticket = ledger.mint(imp1, to: a)
        let r7327 = ledger.callHome(imp1)
        #expect(r7327 == a)
        #expect(!ledger.isAway(imp1) && !ledger.authorises(a, for: imp1))
        // Called home while the holder is away: its late claim or release finds nothing.
        let r1543 = ledger.claim(imp1, ticket: ticket, by: a)
        #expect(r1543 == .refused)
        let late = ledger.release(imp1, ticket: ticket)
        #expect(!late)
        let r3483 = ledger.callHome(imp1)
        #expect(r3483 == nil)
        // The holder hears `gone` when it's next connected, and only once.
        let r8528 = ledger.takeNotices(for: b).isEmpty
        #expect(r8528)
        let r7164 = ledger.takeNotices(for: a)
        #expect(r7164 == [imp1])
        let r6161 = ledger.takeNotices(for: a).isEmpty
        #expect(r6161)
    }

    @Test func callingHomeFromADeviceTakesAllItHolds() {
        var ledger = AwayLedger()
        let i1 = testImp(1).id, i2 = testImp(2).id, i3 = testImp(3).id
        _ = ledger.mint(i1, to: a); _ = ledger.mint(i2, to: a); _ = ledger.mint(i3, to: b)
        #expect(Set(ledger.callHome(from: a)) == [i1, i2])
        #expect(ledger.holder(of: i3) == b && ledger.entries.count == 1)
        #expect(Set(ledger.takeNotices(for: a)) == [i1, i2])
        ledger.dropNotices(for: a)
        let r6161 = ledger.takeNotices(for: a).isEmpty
        #expect(r6161)
    }

    @Test func releaseNeedsTheCurrentTicket() {
        var ledger = AwayLedger()
        let first = ledger.mint(imp1, to: a)
        guard case .granted(let second, _) = ledger.claim(imp1, ticket: first, by: b) else { Issue.record("refused"); return }
        let stale = ledger.release(imp1, ticket: first)
        #expect(!stale && ledger.isAway(imp1))
        let good = ledger.release(imp1, ticket: second)
        #expect(good && !ledger.isAway(imp1))
        let twice = ledger.release(imp1, ticket: second)
        #expect(!twice)
    }

    @Test func comingHomeKillsTheTicketQuietly() {
        var ledger = AwayLedger()
        _ = ledger.mint(imp1, to: a)
        ledger.cameHome(imp1)
        #expect(!ledger.isAway(imp1) && ledger.notices.isEmpty)
    }

    @Test func noticesAreNotDuplicated() {
        var ledger = AwayLedger()
        let t = ledger.mint(imp1, to: a)
        guard case .granted(let t2, _) = ledger.claim(imp1, ticket: t, by: b) else { return }
        guard case .granted(let t3, _) = ledger.claim(imp1, ticket: t2, by: a) else { return }
        _ = ledger.claim(imp1, ticket: t3, by: b)
        #expect(ledger.notices.filter { $0.device == a }.count == 1)
    }
}

@Suite struct LinkVisitsTests {
    let home = linkDevice(1), holder = linkDevice(2), other = linkDevice(3)
    var homeCard: LinkCard { linkCard(home, routes: LinkRoutes(hosts: ["home.local"])) }
    let entry = LinkEntry(side: .right, height: 0.4, speed: 1000)

    @Test func anImpArrivesWithTheWayItCame() throws {
        var visits = Visits()
        let r2277 = visits.arrive(testImp(1), entry: entry, from: home.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        #expect(r2277)
        #expect(visits.travel(of: testImp(1).id) == .visit(side: .right, from: home.id))
        #expect(visits.travel(of: testImp(2).id) == .home)
        #expect(visits.visit(of: testImp(1).id)?.home == homeCard)
    }

    @Test func rotatingAndLeaving() {
        var visits = Visits()
        let first = LinkCrypto.mintTicket(), second = LinkCrypto.mintTicket()
        visits.arrive(testImp(1), entry: entry, from: home.id, home: homeCard, ticket: first)
        visits.rotate(testImp(1).id, ticket: second)
        #expect(visits.visit(of: testImp(1).id)?.ticket == second)
        visits.rotate(UUID(), ticket: first)
        #expect(visits.visits.count == 1)
        let gone = visits.leave(testImp(1).id), again = visits.leave(testImp(1).id)
        #expect(gone?.ticket == second && again == nil)
    }

    @Test func thereIsRoomForTwentyFourAndAReturningVisitorAlwaysHasRoom() {
        var visits = Visits()
        for n in 1...LinkProtocol.maxVisits {
            let took = visits.arrive(testImp(n), entry: entry, from: home.id, home: homeCard, ticket: LinkCrypto.mintTicket())
            #expect(took)
        }
        #expect(visits.isFull)
        let full = visits.arrive(testImp(99), entry: entry, from: home.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        #expect(!full)
        let r8098 = visits.arrive(testImp(5), entry: entry, from: other.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        #expect(r8098)
        #expect(visits.visits.count == LinkProtocol.maxVisits && visits.visit(of: testImp(5).id)?.from == other.id)
    }

    @Test func claimsGoOnlyToTheDeviceWithTheHomesKey() {
        var visits = Visits()
        let ticket = LinkCrypto.mintTicket()
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: ticket)
        #expect(visits.claims(at: home.device).map(\.imp) == [testImp(1).id])
        #expect(visits.claims(at: home.device).first?.ticket == ticket)
        // The same id with another key is not the home.
        let imposter = LinkDevice(id: home.id, name: "Mac", kind: .mac, key: other.publicKey)
        #expect(visits.claims(at: imposter).isEmpty)
        #expect(visits.claims(at: other.device).isEmpty)
        #expect(visits.homeKey(of: home.id) == home.publicKey && visits.homeKey(of: other.id) == nil)
    }

    @Test func sendingHomeWaitsForTheHomeToHear() {
        var visits = Visits()
        let ticket = LinkCrypto.mintTicket()
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: ticket)
        let r6659 = visits.sendHome(testImp(1).id)?.ticket
        #expect(r6659 == ticket)
        #expect(visits.visit(of: testImp(1).id) == nil)
        let waiting = visits.pendingReleases(at: home.device)
        #expect(waiting.count == 1 && waiting[0].ticket == ticket && waiting[0].imp == testImp(1).id)
        #expect(visits.pendingReleases(at: other.device).isEmpty)
        #expect(visits.homes.map(\.id) == [home.id])
        // A claim that crossed the release rotated the ticket: the release goes on with the new one.
        let fresh = LinkCrypto.mintTicket()
        let r9618 = visits.rotateRelease(testImp(1).id, ticket: fresh, at: home.id)
        #expect(r9618)
        let elsewhere = visits.rotateRelease(testImp(1).id, ticket: fresh, at: other.id)
        #expect(!elsewhere)
        #expect(visits.pendingReleases(at: home.device)[0].ticket == fresh)
        visits.delivered(testImp(1).id, at: home.id)
        #expect(visits.releases.isEmpty && visits.homes.isEmpty)
    }

    @Test func sendingHomeEveryImpOfAHome() {
        var visits = Visits()
        for n in 1...3 { visits.arrive(testImp(n), entry: entry, from: holder.id, home: n == 3 ? linkCard(other) : homeCard, ticket: LinkCrypto.mintTicket()) }
        #expect(Set(visits.sendHome(of: home.id).map(\.imp.id)) == [testImp(1).id, testImp(2).id])
        #expect(visits.visits.map(\.imp.id) == [testImp(3).id] && visits.releases.count == 2)
    }

    @Test func oldReleasesAreDropped() {
        var visits = Visits()
        let now = Date()
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        visits.sendHome(testImp(1).id, now: now)
        visits.expire(now: now.addingTimeInterval(Visits.releaseLife - 1))
        #expect(visits.releases.count == 1)
        visits.expire(now: now.addingTimeInterval(Visits.releaseLife + 1))
        #expect(visits.releases.isEmpty)
    }

    @Test func comingBackReplacesAWaitingRelease() {
        var visits = Visits()
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        visits.sendHome(testImp(1).id)
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        #expect(visits.releases.isEmpty && visits.visit(of: testImp(1).id) != nil)
    }

    @Test func looksUpdateInPlace() {
        var visits = Visits()
        visits.arrive(testImp(1), entry: entry, from: holder.id, home: homeCard, ticket: LinkCrypto.mintTicket())
        var look = testImp(1)
        look.hue = 0.9
        visits.update(look)
        visits.update(testImp(7))
        #expect(visits.visit(of: testImp(1).id)?.imp.hue == 0.9 && visits.visits.count == 1)
    }
}

@Suite struct LinkAccessTests {
    let home = linkDevice(1), holder = linkDevice(2), other = linkDevice(3)

    @Test func onlyTheHolderAsksAnImp() {
        var ledger = AwayLedger()
        _ = ledger.mint(testImp(1).id, to: holder.id)
        let visits = Visits()
        for message: LinkMessage in [.ask(imp: testImp(1).id, text: "hi"), .stop(imp: testImp(1).id), .newChat(imp: testImp(1).id),
                                     .felt(imp: testImp(1).id, feeling: .poke), .file(id: UUID(), imp: testImp(1).id, ref: "a.png"), .talks(imp: testImp(1).id)] {
            #expect(LinkAccess.allows(message, from: holder.id, standing: .visitor, ledger: ledger, visits: visits))
            #expect(LinkAccess.allows(message, from: holder.id, standing: .peer, ledger: ledger, visits: visits))
            #expect(!LinkAccess.allows(message, from: other.id, standing: .peer, ledger: ledger, visits: visits))
            #expect(!LinkAccess.allows(message, from: other.id, standing: .visitor, ledger: ledger, visits: visits))
        }
    }

    @Test func aHomeOnlyTellsItsOwnVisitors() {
        var visits = Visits()
        visits.arrive(testImp(1), entry: LinkEntry(side: .left, height: 0, speed: 0), from: holder.id, home: linkCard(home), ticket: LinkCrypto.mintTicket())
        let ledger = AwayLedger()
        let work: LinkMessage = .work(imp: testImp(1).id, work: nil)
        #expect(LinkAccess.allows(work, from: home.id, standing: .visitor, ledger: ledger, visits: visits))
        #expect(!LinkAccess.allows(work, from: other.id, standing: .peer, ledger: ledger, visits: visits))
        #expect(!LinkAccess.allows(.mood(imp: testImp(2).id, mood: "happy"), from: home.id, standing: .peer, ledger: ledger, visits: visits))
        #expect(LinkAccess.allows(.look(imp: testImp(1)), from: home.id, standing: .peer, ledger: ledger, visits: visits))
        #expect(!LinkAccess.allows(.look(imp: testImp(1)), from: other.id, standing: .peer, ledger: ledger, visits: visits))
        let part: LinkMessage = .filePart(id: UUID(), part: LinkFilePart(name: "a", size: 1, offset: 0, data: Data([1])))
        #expect(LinkAccess.allows(part, from: home.id, standing: .visitor, ledger: ledger, visits: visits))
        #expect(!LinkAccess.allows(part, from: other.id, standing: .visitor, ledger: ledger, visits: visits))
    }

    @Test func visitorsMayOnlyUseTickets() {
        let ledger = AwayLedger(), visits = Visits()
        for message: LinkMessage in [.stage(imps: []), .routes(door: LinkCrypto.randomKey(), routes: .none), .took(transfer: UUID()),
                                     .pass(transfer: UUID(), imp: testImp(1), entry: LinkEntry(side: .left, height: 0, speed: 0), home: nil, ticket: nil),
                                     .adopt(transfer: UUID(), imp: UUID(), kit: "", secrets: LinkSecrets(), entry: LinkEntry(side: .left, height: 0, speed: 0))] {
            #expect(!LinkAccess.allows(message, from: other.id, standing: .visitor, ledger: ledger, visits: visits))
            #expect(LinkAccess.allows(message, from: other.id, standing: .peer, ledger: ledger, visits: visits))
        }
        for message: LinkMessage in [.claim(imp: UUID(), ticket: LinkCrypto.mintTicket()), .release(imp: UUID(), ticket: LinkCrypto.mintTicket()), .ping, .bye(reason: "")] {
            #expect(LinkAccess.allows(message, from: other.id, standing: .visitor, ledger: ledger, visits: visits))
        }
        #expect(!LinkAccess.allows(.hello(device: UUID(), name: "", kind: .mac, key: Data(), version: 2, proof: Data(), join: nil), from: other.id, standing: .peer, ledger: ledger, visits: visits))
    }

    @Test func aVisitorMayAskOnlyWhatItHolds() {
        var ledger = AwayLedger()
        _ = ledger.mint(testImp(2).id, to: holder.id)
        let ask: (UUID) -> LinkMessage = { .message(id: UUID(), from: testImp(1), to: $0, toHome: UUID(), text: "?", forwarded: false) }
        #expect(LinkAccess.allows(ask(testImp(2).id), from: holder.id, standing: .visitor, ledger: ledger, visits: Visits()))
        #expect(!LinkAccess.allows(ask(testImp(3).id), from: holder.id, standing: .visitor, ledger: ledger, visits: Visits()))
        #expect(LinkAccess.allows(ask(testImp(3).id), from: holder.id, standing: .peer, ledger: ledger, visits: Visits()))
    }
}
