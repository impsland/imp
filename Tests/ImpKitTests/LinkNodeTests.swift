import Foundation
import Testing
@testable import ImpKit

// Real nodes in one process over 127.0.0.1: Bonjour and the network watcher off, books in memory.
// Everything waits for events with a timeout, never for a fixed time.

/// A node and everything it told the app, in order.
@MainActor
private final class Probe {
    let node: LinkNode
    let storage: LinkStorage
    private(set) var events: [LinkNode.Event] = []
    var device: LinkDevice { node.device }
    var id: UUID { node.device.id }

    init(_ n: Int, storage: LinkStorage = LinkMemoryStorage(), kind: LinkKind = .mac, tweak: (inout LinkNode.Options) -> Void = { _ in }) throws {
        var options = LinkNode.Options()
        options.port = nil
        options.bonjour = false
        options.watchesNetwork = false
        options.hosts = ["127.0.0.1"]
        options.tick = 0.05
        options.visitorGrace = 0.6
        options.handshakeTimeout = 3
        options.transferTimeout = 3
        options.retryStart = 0.1
        options.retryLongest = 0.4
        options.joinTimeout = 6
        tweak(&options)
        self.storage = storage
        node = try LinkNode(name: "Device \(n)", kind: kind, id: linkDevice(n).id, storage: storage, options: options)
        node.onEvent = { [weak self] in self?.events.append($0) }
    }

    func start() async { await node.start() }

    /// The first event not yet taken that `match` likes, waiting up to `seconds` for it.
    @discardableResult
    func take(_ seconds: Double = 5, _ match: (LinkNode.Event) -> Bool) async -> LinkNode.Event? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let i = events.firstIndex(where: match) { return events.remove(at: i) }
            if Date() > end { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func has(_ match: (LinkNode.Event) -> Bool) -> Bool { events.contains(where: match) }

    func connected(to other: Probe, as standing: LinkStanding) async -> Bool {
        await until { self.node.standing(of: other.id) == standing }
    }

    func receivedMessage(_ seconds: Double = 5, _ match: (LinkMessage, UUID) -> Bool) async -> LinkMessage? {
        let event = await take(seconds) { if case .message(let m, let from) = $0 { return match(m, from) } else { return false } }
        if case .message(let m, _)? = event { return m }
        return nil
    }

    func passed(_ seconds: Double = 5, _ match: (LinkNode.Passed) -> Bool = { _ in true }) async -> LinkNode.Passed? {
        let event = await take(seconds) { if case .passed(let p) = $0 { return match(p) } else { return false } }
        if case .passed(let p)? = event { return p }
        return nil
    }
}

@MainActor
private func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// `guest` scans a fresh code of `host`; both end up connected as peers.
@MainActor
private func link(_ host: Probe, _ guest: Probe) async throws {
    let invite = host.node.invite()
    let device = try await guest.node.join(invite)
    #expect(device.id == host.id)
    #expect(await guest.connected(to: host, as: .peer))
    #expect(await host.connected(to: guest, as: .peer))
}

private let entry = LinkEntry(side: .right, height: 0.5, speed: 900)

/// `from` throws `imp` to `to`, which takes it. Returns the transfer.
@MainActor
@discardableResult
private func throwImp(_ imp: LinkImp, from: Probe, to: Probe, accepting: Bool = true) async throws -> UUID {
    let transfer = try #require(from.node.pass(imp, entry: entry, to: to.id))
    let arrived = await to.receivedMessage { m, _ in if case .pass(let t, _, _, _, _) = m { return t == transfer } else { return false } }
    #expect(arrived != nil)
    if accepting { #expect(to.node.accept(transfer)) }
    return transfer
}

@MainActor
@Suite(.serialized) struct LinkNodeTests {
    @Test func aGuestJoinsWithAFreshInvite() async throws {
        let host = try Probe(1), guest = try Probe(2, kind: .phone)
        await host.start(); await guest.start()
        defer { host.node.stop(); guest.node.stop() }
        let invite = host.node.invite()
        #expect(invite.routes.port == host.node.port && invite.routes.hosts == ["127.0.0.1"])
        let device = try await guest.node.join(invite)
        #expect(device == host.device)
        // Both sides pinned the other's key, and both heard about it.
        #expect(await host.take { if case .linked(let d) = $0 { return d.id == guest.id && d.key == guest.device.key } else { return false } } != nil)
        #expect(await guest.take { if case .linked(let d) = $0 { return d.id == host.id } else { return false } } != nil)
        #expect(host.node.links.map(\.id) == [guest.id] && guest.node.links.map(\.id) == [host.id])
        #expect(host.node.links.first?.device.kind == .phone)
        #expect(await host.connected(to: guest, as: .peer))
        #expect(await guest.connected(to: host, as: .peer))
        // The host learns the guest's door and addresses from its `routes`.
        #expect(await until { host.node.links.first?.door != nil && host.node.links.first?.routes.port == guest.node.port })
        // A saved book comes back as the same device with the same links.
        let again = try LinkNode(name: "x", kind: .mac, storage: host.storage)
        #expect(again.device.id == host.id && again.device.key == host.device.key && again.links.map(\.id) == [guest.id])
    }

    @Test func aPinnedPeerReconnects() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        #expect(await until { a.node.links.first?.door != nil })
        #expect(await a.take { if case .linked = $0 { return true } else { return false } } != nil)
        b.node.stop()
        #expect(await a.take { if case .disconnected(let id) = $0 { return id == b.id } else { return false } } != nil)
        #expect(a.node.standing(of: b.id) == nil)
        await b.start()
        #expect(await a.connected(to: b, as: .peer))
        #expect(await b.connected(to: a, as: .peer))
        // No new link was made.
        #expect(!a.has { if case .linked = $0 { return true } else { return false } })
        #expect(a.node.links.count == 1 && b.node.links.count == 1)
    }

    @Test func anExpiredInviteMakesAVisitorThatIsClosed() async throws {
        let host = try Probe(1) { $0.inviteLife = 0.05 }, guest = try Probe(2)
        await host.start(); await guest.start()
        defer { host.node.stop(); guest.node.stop() }
        let invite = host.node.invite()
        host.node.inviteHidden()
        try await Task.sleep(for: .milliseconds(120))
        await #expect(throws: LinkNode.JoinError.refused) { try await guest.node.join(invite) }
        // The host saw a visitor, not a peer, and nothing was linked.
        let visitor = await host.take { if case .connected(let d, .visitor) = $0 { return d.id == guest.id } else { return false } }
        #expect(visitor != nil)
        #expect(await host.take { if case .disconnected(let id) = $0 { return id == guest.id } else { return false } } != nil)
        #expect(host.node.links.isEmpty && guest.node.links.isEmpty)
        #expect(guest.has { if case .problem(.inviteRefused(let id)) = $0 { return id == host.id } else { return false } })
    }

    @Test func aReplacedInviteStopsWorking() async throws {
        let host = try Probe(1), guest = try Probe(2)
        await host.start(); await guest.start()
        defer { host.node.stop(); guest.node.stop() }
        let old = host.node.invite()
        _ = host.node.invite()
        await #expect(throws: LinkNode.JoinError.refused) { try await guest.node.join(old) }
        #expect(host.node.links.isEmpty)
    }

    @Test func aVisitorWithoutAValidClaimIsClosedAfterTheGrace() async throws {
        let host = try Probe(1) { $0.visitorGrace = 0.3 }
        // The guest believes an Imp of the host's is visiting, with a ticket the host never gave.
        let stranger = linkDevice(5)
        var book = LinkBook(device: linkDevice(2).id, seed: linkDevice(2).seed, door: LinkCrypto.randomKey())
        await host.start()
        defer { host.node.stop() }
        book.visits.arrive(testImp(1), entry: entry, from: stranger.id, home: host.node.card, ticket: LinkCrypto.mintTicket())
        let guest = try Probe(2, storage: LinkMemoryStorage(book))
        await guest.start()
        defer { guest.node.stop() }
        let visitor = await host.take { if case .connected(let d, .visitor) = $0 { return d.id == guest.id } else { return false } }
        #expect(visitor != nil)
        // Its claim is refused: `gone`, and the body is dropped.
        #expect(await guest.receivedMessage { m, from in if case .gone = m { return from == host.id } else { return false } } != nil)
        #expect(await until { guest.node.visits.visits.isEmpty })
        #expect(await host.take { if case .disconnected(let id) = $0 { return id == guest.id } else { return false } } != nil)
        #expect(host.node.links.isEmpty && host.node.away.entries.isEmpty)
    }

    @Test func aWrongDoorFailsTheTLSHandshake() async throws {
        let host = try Probe(1), guest = try Probe(2)
        await host.start(); await guest.start()
        defer { host.node.stop(); guest.node.stop() }
        var invite = host.node.invite()
        invite.door = LinkCrypto.randomKey()
        await #expect(throws: LinkNode.JoinError.refused) { try await guest.node.join(invite) }
        #expect(guest.has { if case .problem(.refused(let id)) = $0 { return id == host.id } else { return false } })
        #expect(!host.has { if case .connected = $0 { return true } else { return false } })
        #expect(host.node.connected.isEmpty && host.node.links.isEmpty)
    }

    @Test func aPinnedPeerWithAnotherKeyIsClosed() async throws {
        let host = try Probe(1), guest = try Probe(2)
        await host.start(); await guest.start()
        defer { host.node.stop(); guest.node.stop() }
        try await link(host, guest)
        // Someone with the guest's id and another key, holding a fresh code (and so the door).
        let invite = host.node.invite()
        let fake = try Probe(2)
        await fake.start()
        defer { fake.node.stop() }
        #expect(fake.device.id == guest.id && fake.device.key != guest.device.key)
        await #expect(throws: LinkNode.JoinError.self) { try await fake.node.join(invite) }
        #expect(await host.take { if case .problem(.keyChanged(let id)) = $0 { return id == guest.id } else { return false } } != nil)
        #expect(host.node.links.first?.device.key == guest.device.key)
        #expect(fake.node.links.isEmpty)
    }

    @Test func aHostWithAnotherKeyThanPinnedIsRefusedByTheGuest() async throws {
        let host = try Probe(1), guest = try Probe(2), fake = try Probe(1)
        await host.start(); await guest.start(); await fake.start()
        defer { host.node.stop(); guest.node.stop(); fake.node.stop() }
        var invite = host.node.invite()
        // The code names the real host's key, but the address leads to an impostor with the same door.
        let impostor = fake.node.invite()
        invite.routes = impostor.routes
        invite.door = impostor.door
        invite.invite = impostor.invite
        await #expect(throws: LinkNode.JoinError.refused) { try await guest.node.join(invite) }
        #expect(guest.has { if case .problem(.keyChanged(let id)) = $0 { return id == host.id } else { return false } })
        #expect(guest.node.links.isEmpty)
    }

    @Test func anImpPassesAndIsTaken() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        #expect(a.node.door(of: imp.id, side: .left, height: 0.3) == .to(b.id))
        #expect(a.node.door(of: imp.id, side: .right, height: 0.9) == .to(b.id))
        let transfer = try await throwImp(imp, from: a, to: b)
        let result = await a.passed()
        #expect(result == LinkNode.Passed(transfer: transfer, imp: imp.id, to: b.id, kind: .pass, outcome: .took))
        // B has a visitor from A; A knows B holds it; B's claim rotated the ticket.
        #expect(b.node.visits.visit(of: imp.id)?.home.id == a.id)
        #expect(b.node.travel(of: imp.id) == .visit(side: .right, from: a.id))
        #expect(await until { a.node.holder(of: imp.id) == b.id && a.node.away.entry(of: imp.id)?.generation == 2 })
        let ticket = try #require(b.node.visits.visit(of: imp.id)?.ticket)
        #expect(await until { LinkCrypto.matches(ticket: ticket, hash: a.node.away.entry(of: imp.id)?.ticket ?? Data()) || b.node.visits.visit(of: imp.id)?.ticket != ticket })
        // Only the holder is answered; A hears the claim.
        #expect(await a.receivedMessage { m, from in if case .claim = m { return from == b.id } else { return false } } != nil)
        b.node.send(.ask(imp: imp.id, text: "hi"), to: a.id)
        #expect(await a.receivedMessage { m, _ in if case .ask = m { return true } else { return false } } != nil)
        // Thrown back where it came from it is home again, and its tickets die.
        #expect(b.node.door(of: imp.id, side: .right, height: 0.5) == .to(a.id))
        try await throwImp(imp, from: b, to: a)
        #expect(await b.passed()?.outcome == .took)
        #expect(await until { b.node.visits.visits.isEmpty && !a.node.away.isAway(imp.id) })
        a.node.send(.ask(imp: imp.id, text: "x"), to: b.id)
    }

    @Test func aDeclinedImpBouncesAndIsNotAway() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let transfer = try await throwImp(testImp(1), from: a, to: b, accepting: false)
        b.node.decline(transfer, reason: .playing)
        let result = await a.passed()
        #expect(result?.outcome == .declined(.playing))
        #expect(!a.node.away.isAway(testImp(1).id) && b.node.visits.visits.isEmpty)
        // A late accept finds nothing to take.
        #expect(!b.node.accept(transfer))
    }

    @Test func aThrowNobodyAnswersTimesOutAndTheImpIsCalledHome() async throws {
        let a = try Probe(1) { $0.transferTimeout = 0.3 }, b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let transfer = try #require(a.node.pass(testImp(1), entry: entry, to: b.id))
        let result = await a.passed()
        #expect(result?.transfer == transfer && result?.outcome == .declined(.timeout))
        #expect(!a.node.away.isAway(testImp(1).id))
        // B takes it after all: its claim is refused, `gone` comes back and the body goes.
        let arrived = await b.receivedMessage { m, _ in if case .pass = m { return true } else { return false } }
        #expect(arrived != nil)
        #expect(b.node.accept(transfer))
        #expect(await until { b.node.visits.visits.isEmpty })
        #expect(!a.node.away.isAway(testImp(1).id) && a.node.away.notices.isEmpty)
    }

    @Test func aRepeatedTransferIsAnsweredAgainNotTakenTwice() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let transfer = try await throwImp(testImp(1), from: a, to: b)
        #expect(await a.passed()?.outcome == .took)
        let before = b.node.visits
        // The same pass arriving again is answered again by the node, and never reaches the app or the visits twice.
        a.node.send(.pass(transfer: transfer, imp: testImp(1), entry: entry, home: a.node.card, ticket: LinkCrypto.mintTicket()), to: b.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(b.node.visits == before)
        #expect(!b.has { if case .message(.pass, _) = $0 { return true } else { return false } })
    }

    @Test func aThirdDeviceClaimsATicketAsAVisitor() async throws {
        let a = try Probe(1), b = try Probe(2), c = try Probe(3)
        await a.start(); await b.start(); await c.start()
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        try await link(a, b)
        try await link(c, b)
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await a.passed()?.outcome == .took)
        #expect(await until { a.node.away.entry(of: imp.id)?.generation == 2 })
        // B passes the visiting Imp on through its forward side; C is not linked to A.
        #expect(b.node.door(of: imp.id, side: .left, height: 0.5) == .to(c.id))
        #expect(b.node.door(of: imp.id, side: .right, height: 0.5) == .to(a.id))
        try await throwImp(imp, from: b, to: c)
        #expect(await b.passed()?.outcome == .took)
        #expect(b.node.visits.visits.isEmpty)
        #expect(c.node.links.map(\.id) == [b.id])
        // C reaches A as a visitor and claims: A rotates the ticket and C is the holder.
        let visitor = await a.take { if case .connected(let d, .visitor) = $0 { return d.id == c.id } else { return false } }
        #expect(visitor != nil)
        #expect(await until { a.node.holder(of: imp.id) == c.id && a.node.away.entry(of: imp.id)?.generation == 3 })
        #expect(await until {
            guard let ticket = c.node.visits.visit(of: imp.id)?.ticket, let hash = a.node.away.entry(of: imp.id)?.ticket else { return false }
            return LinkCrypto.matches(ticket: ticket, hash: hash)
        })
        #expect(a.node.standing(of: c.id) == .visitor || a.node.standing(of: c.id) == nil)
        // A visitor with a ticket can act for its Imp, and only for that one.
        c.node.send(.ask(imp: imp.id, text: "hello"), to: a.id)
        #expect(await a.receivedMessage { m, from in if case .ask = m { return from == c.id } else { return false } } != nil)
        c.node.send(.ask(imp: testImp(2).id, text: "not mine"), to: a.id)
        #expect(await a.receivedMessage(0.3) { m, _ in if case .ask(let i, _) = m { return i == testImp(2).id } else { return false } } == nil)
        // The visitor's connection stays: it holds a ticket (the grace is over by now).
        try await Task.sleep(for: .milliseconds(800))
        #expect(a.node.isConnected(c.id))
    }

    @Test func anImpOfTheHolderAsksTheVisitorItHoldsEvenWhenOnlyVisitingItsHome() async throws {
        let a = try Probe(1), b = try Probe(2), c = try Probe(3)
        await a.start(); await b.start(); await c.start()
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        try await link(a, b)
        try await link(c, b)
        let visitor = testImp(1), local = testImp(7)
        try await throwImp(visitor, from: a, to: b)
        #expect(await a.passed()?.outcome == .took)
        try await throwImp(visitor, from: b, to: c)
        #expect(await b.passed()?.outcome == .took)
        #expect(await until { a.node.holder(of: visitor.id) == c.id })
        // C's own Imp and the visitor share C's screen; A hears about it though C only visits A.
        c.node.setStage([LinkStaged(imp: visitor, home: a.id), LinkStaged(imp: local, home: c.id)])
        #expect(await until { a.node.stage(of: c.id).count == 2 })
        let q = UUID()
        #expect(c.node.talk(id: q, from: local, to: visitor.id, toHome: a.id, text: "hello?", holder: c.id) == .via(a.id))
        let asked = await a.receivedMessage { m, from in if case .message(let id, _, _, _, _, _) = m { return id == q && from == c.id } else { return false } }
        #expect(asked != nil)
    }

    @Test func theNewestHolderWinsAndThePreviousOneHearsGone() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await until { a.node.away.entry(of: imp.id)?.generation == 2 })
        let held = try #require(b.node.visits.visit(of: imp.id)?.ticket)
        // A third device that thinks it holds the Imp with the very same ticket (a throw that seemed lost).
        let seed = linkDevice(3)
        var book = LinkBook(device: seed.id, seed: seed.seed, door: LinkCrypto.randomKey())
        book.visits.arrive(imp, entry: entry, from: b.id, home: a.node.card, ticket: held)
        let c = try Probe(3, storage: LinkMemoryStorage(book))
        await c.start()
        defer { c.node.stop() }
        // Its claim comes first: C is the holder and B, which still has a body, hears `gone`.
        #expect(await b.receivedMessage { m, from in if case .gone(let i) = m { return i == imp.id && from == a.id } else { return false } } != nil)
        #expect(a.node.holder(of: imp.id) == c.id && b.node.visits.visits.isEmpty)
        #expect(await until { c.node.visits.visit(of: imp.id)?.ticket != held })
        // B's own claim with the ticket it had is refused now, and C stays.
        b.node.send(.claim(imp: imp.id, ticket: held), to: a.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.node.holder(of: imp.id) == c.id && a.node.away.entry(of: imp.id)?.generation == 3)
    }

    @Test func callingHomeTellsTheHolderEvenIfItIsOffline() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await until { a.node.holder(of: imp.id) == b.id })
        // Connected: `gone` right away.
        #expect(a.node.callHome(imp.id) == b.id)
        let gone = await b.receivedMessage { m, _ in if case .gone(let i) = m { return i == imp.id } else { return false } }
        #expect(gone != nil && b.node.visits.visits.isEmpty && !a.node.away.isAway(imp.id))

        // Offline: the news waits for the next connection.
        let other = testImp(2)
        try await throwImp(other, from: a, to: b)
        #expect(await until { a.node.holder(of: other.id) == b.id })
        b.node.stop()
        #expect(await until { !a.node.isConnected(b.id) })
        #expect(a.node.callHome(other.id) == b.id)
        #expect(a.node.away.notices == [AwayLedger.Notice(device: b.id, imp: other.id)])
        await b.start()
        let late = await b.receivedMessage { m, _ in if case .gone(let i) = m { return i == other.id } else { return false } }
        #expect(late != nil)
        #expect(await until { a.node.away.notices.isEmpty && b.node.visits.visits.isEmpty })
    }

    @Test func aReleaseSentWhileOfflineIsDeliveredLater() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await until { a.node.away.entry(of: imp.id)?.generation == 2 && b.node.visits.visit(of: imp.id) != nil })
        let ticket = try #require(b.node.visits.visit(of: imp.id)?.ticket)
        #expect(await until { LinkCrypto.matches(ticket: ticket, hash: a.node.away.entry(of: imp.id)?.ticket ?? Data()) })
        b.node.stop()
        #expect(b.node.sendHome(imp.id))
        #expect(b.node.visits.visits.isEmpty && b.node.visits.releases.count == 1)
        #expect(a.node.away.isAway(imp.id))
        await b.start()
        #expect(await a.receivedMessage { m, from in if case .release(let i, _) = m { return i == imp.id && from == b.id } else { return false } } != nil)
        #expect(await until { !a.node.away.isAway(imp.id) && b.node.visits.releases.isEmpty })
    }

    @Test func forgettingEndsTheLinkOnBothSides() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await until { a.node.holder(of: imp.id) == b.id })
        let result = a.node.forget(b.id)
        #expect(result.calledHome == [imp.id] && a.node.links.isEmpty && !a.node.away.isAway(imp.id))
        #expect(await b.take { if case .forgotten(let id, _) = $0 { return id == a.id } else { return false } } != nil)
        #expect(b.node.links.isEmpty)
        #expect(await until { !a.node.isConnected(b.id) && !b.node.isConnected(a.id) })
    }

    @Test func forgettingEveryoneMakesANewDoor() async throws {
        let a = try Probe(1), b = try Probe(2), c = try Probe(3)
        await a.start(); await b.start(); await c.start()
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        let old = a.node.invite()
        try await link(a, b)
        a.node.forgetEveryone()
        #expect(a.node.links.isEmpty && a.node.card.door != old.door)
        #expect(await until { a.node.connected.isEmpty })
        await #expect(throws: LinkNode.JoinError.self) { try await c.node.join(old) }
    }

    @Test func questionsBetweenImpsGoToTheTargetsHomeAndForwardOnce() async throws {
        // A and C are both linked to B only. A's Imp (held by B) asks an Imp of C.
        let a = try Probe(1), b = try Probe(2), c = try Probe(3)
        await a.start(); await b.start(); await c.start()
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        try await link(b, a)
        try await link(b, c)
        let asker = testImp(1), target = testImp(9), far = testImp(8)
        // A's Imp is on A's screen with B's Imp 9 (B threw it to A); B's Imp 8 is held by A too.
        try await throwImp(target, from: b, to: a)
        a.node.setStage([LinkStaged(imp: asker, home: a.id), LinkStaged(imp: target, home: b.id)])
        #expect(await until { b.node.stage(of: a.id).count == 2 })
        let q = UUID()
        // Straight to a connected home: A asks B.
        #expect(a.node.talk(id: q, from: asker, to: target.id, toHome: b.id, text: "hi", holder: a.id) == .via(b.id))
        let direct = await b.receivedMessage { m, from in if case .message(let id, _, _, _, _, let forwarded) = m { return id == q && !forwarded && from == a.id } else { return false } }
        #expect(direct != nil)
        b.node.send(.answer(id: q, text: "hello", failed: false), to: a.id)
        let back = await a.receivedMessage { m, _ in if case .answer(let id, "hello", false) = m { return id == q } else { return false } }
        #expect(back != nil)
        // The same question id can't be in flight twice.
        let again = UUID()
        #expect(a.node.talk(id: again, from: asker, to: target.id, toHome: b.id, text: "1", holder: a.id) == .via(b.id))
        #expect(a.node.talk(id: again, from: asker, to: target.id, toHome: b.id, text: "2", holder: a.id) == .unreachable)

        // A's Imp is held by B and the target lives on C: A can only reach B, which forwards once.
        try await throwImp(asker, from: a, to: b)
        try await throwImp(far, from: c, to: b)
        b.node.setStage([LinkStaged(imp: asker, home: a.id), LinkStaged(imp: far, home: c.id)])
        #expect(await until { c.node.stage(of: b.id).count == 2 })
        let q2 = UUID()
        #expect(a.node.talk(id: q2, from: asker, to: far.id, toHome: c.id, text: "you there?", holder: b.id) == .via(b.id))
        let forwarded = await c.receivedMessage { m, from in if case .message(let id, _, _, _, let text, let forwarded) = m { return id == q2 && forwarded && text == "you there?" && from == b.id } else { return false } }
        #expect(forwarded != nil)
        c.node.send(.answer(id: q2, text: "yes", failed: false), to: b.id)
        let relayed = await a.receivedMessage { m, from in if case .answer(let id, "yes", false) = m { return id == q2 && from == b.id } else { return false } }
        #expect(relayed != nil)
        // B did not ask the app about it: it only passed it on.
        #expect(!b.has { if case .message(.message(let id, _, _, _, _, _), _) = $0 { return id == q2 } else { return false } })

        // A question that was forwarded already isn't forwarded again, even to a home that is connected.
        let q3 = UUID()
        c.node.send(.message(id: q3, from: asker, to: target.id, toHome: a.id, text: "x", forwarded: true), to: b.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!a.has { if case .message(.message(let id, _, _, _, _, _), _) = $0 { return id == q3 } else { return false } })
        // Nobody to ask: nothing is sent.
        #expect(a.node.talk(id: UUID(), from: asker, to: target.id, toHome: UUID(), text: "?", holder: a.id) == .unreachable)
    }

    @Test func aQuestionNobodyAnswersFails() async throws {
        let a = try Probe(1) { $0.answerTimeout = 0.3 }, b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let q = UUID()
        #expect(a.node.talk(id: q, from: testImp(1), to: UUID(), toHome: b.id, text: "?", holder: a.id) == .via(b.id))
        let failed = await a.receivedMessage { m, _ in if case .answer(let id, _, true) = m { return id == q } else { return false } }
        #expect(failed != nil)
    }
}

// MARK: Authority, trust, consistency and limits

private func saved(_ probe: Probe) throws -> LinkBook {
    let book = try probe.storage.load()
    return try #require(book)
}

extension LinkNodeTests {
    @Test func aQuestionForAnImpIsOnlyPutByWhatIsOnItsScreen() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let asker = testImp(1), target = testImp(9)
        b.node.setStage([LinkStaged(imp: target, home: b.id)])
        #expect(await until { a.node.stage(of: b.id).count == 1 })
        // The asker isn't on B's screen: failed, and the app is never asked.
        let q = UUID()
        #expect(a.node.talk(id: q, from: asker, to: target.id, toHome: b.id, text: "hi", holder: a.id) == .via(b.id))
        #expect(await a.receivedMessage { m, _ in if case .answer(let id, _, true) = m { return id == q } else { return false } } != nil)
        #expect(!b.has { if case .message(.message, _) = $0 { return true } else { return false } })
        // Once it visits B's screen it may ask.
        b.node.setStage([LinkStaged(imp: target, home: b.id), LinkStaged(imp: asker, home: a.id)])
        #expect(await until { a.node.stage(of: b.id).count == 2 })
        let q2 = UUID()
        #expect(a.node.talk(id: q2, from: asker, to: target.id, toHome: b.id, text: "hi", holder: a.id) == .via(b.id))
        #expect(await b.receivedMessage { m, _ in if case .message(let id, _, _, _, _, _) = m { return id == q2 } else { return false } } != nil)
    }

    @Test func whatIsNotTheirsAnyMoreGetsGoneNotSilence() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        // B thinks it holds an Imp of A's that A has at home.
        func stale() {
            b.node.book.visits.arrive(imp, entry: entry, from: a.id, home: a.node.card, ticket: LinkCrypto.mintTicket())
        }
        stale()
        let id = UUID()
        b.node.send(.file(id: id, imp: imp.id, ref: "x.png"), to: a.id)
        #expect(await b.receivedMessage { m, from in if case .fileFailed(let f, _) = m { return f == id && from == a.id } else { return false } } != nil)
        #expect(await b.receivedMessage { m, from in if case .gone(let g) = m { return g == imp.id && from == a.id } else { return false } } != nil)
        #expect(b.node.visits.visits.isEmpty)
        stale()
        b.node.send(.ask(imp: imp.id, text: "hi"), to: a.id)
        #expect(await b.receivedMessage { m, _ in if case .gone = m { return true } else { return false } } != nil)
        #expect(!a.has { if case .message(.ask, _) = $0 { return true } else { return false } })
    }

    @Test func aThrownImpMayNotBeOneWeHaveOrHold() async throws {
        let a = try Probe(1), b = try Probe(2), c = try Probe(3)
        await a.start(); await b.start(); await c.start()
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        try await link(a, b); try await link(a, c)
        // B pretends to hold an Imp of its own that A has at home.
        let mine = testImp(1)
        a.node.setStage([LinkStaged(imp: mine, home: a.id)])
        b.node.book.visits.arrive(mine, entry: entry, from: c.id, home: b.node.card, ticket: LinkCrypto.mintTicket())
        #expect(b.node.pass(mine, entry: entry, to: a.id) != nil)
        #expect(await b.passed()?.outcome == .declined(.other))
        // An Imp of C's already visiting A from C can't come in again from B.
        let visitor = testImp(2)
        try await throwImp(visitor, from: c, to: a)
        b.node.book.visits.arrive(visitor, entry: entry, from: c.id, home: c.node.card, ticket: LinkCrypto.mintTicket())
        #expect(b.node.pass(visitor, entry: entry, to: a.id) != nil)
        #expect(await b.passed()?.outcome == .declined(.other))
        #expect(a.node.visits.visit(of: visitor.id)?.from == c.id)
        // Only the holder brings an away Imp home.
        let away = testImp(3)
        try await throwImp(away, from: a, to: c)
        b.node.book.visits.arrive(away, entry: entry, from: c.id, home: a.node.card, ticket: LinkCrypto.mintTicket())
        #expect(b.node.pass(away, entry: entry, to: a.id) != nil)
        #expect(await b.passed()?.outcome == .declined(.notLinked))
        #expect(a.node.holder(of: away.id) == c.id)
    }

    @Test func theAppCanTellWhetherAThrowCanStillBeTaken() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let transfer = try await throwImp(testImp(1), from: a, to: b, accepting: false)
        #expect(b.node.canAccept(transfer))
        #expect(!b.node.canAccept(UUID()))
        b.node.decline(transfer, reason: .other)
        #expect(!b.node.canAccept(transfer))
        #expect(!b.node.accept(transfer))
        let second = try await throwImp(testImp(2), from: a, to: b)
        #expect(!b.node.canAccept(second))
    }

    @Test func trustIsPerLinkAndNeverForOthers() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        #expect(!a.node.isTrusted(b.id))
        a.node.setTrusted(b.id, true)   // not linked yet
        #expect(!a.node.isTrusted(b.id))
        try await link(a, b)
        #expect(!a.node.isTrusted(b.id) && !a.node.links[0].trusted)
        a.node.setTrusted(b.id, true)
        #expect(a.node.isTrusted(b.id))
        // It is kept, and a book from before trust existed reads as nobody trusted.
        let again = try LinkNode(name: "x", kind: .mac, storage: a.storage)
        #expect(again.isTrusted(b.id))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder.link.encode(saved(a))) as? [String: Any])
        json["passing"] = nil
        json["links"] = (json["links"] as? [[String: Any]])?.map { var l = $0; l["trusted"] = nil; return l }
        let old = try JSONDecoder.link.decode(LinkBook.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.links.count == 1 && !old.links[0].trusted && old.passing.isEmpty)
        // Requests are as trusted as the device they come from; a question as its asker's home.
        let imp = testImp(1)
        #expect(a.node.isTrusted(.ask(imp: imp.id, text: "x"), from: b.id))
        #expect(!a.node.isTrusted(.ask(imp: imp.id, text: "x"), from: UUID()))
        let question = LinkMessage.message(id: UUID(), from: imp, to: UUID(), toHome: a.id, text: "?", forwarded: false)
        #expect(!a.node.isTrusted(question, from: b.id))   // nobody said where the asker lives
        b.node.setStage([LinkStaged(imp: imp, home: b.id)])
        #expect(await until { a.node.stage(of: b.id).count == 1 })
        #expect(a.node.isTrusted(question, from: b.id))
        a.node.setTrusted(b.id, false)
        #expect(!a.node.isTrusted(question, from: b.id) && !a.node.isTrusted(.file(id: UUID(), imp: imp.id, ref: "x"), from: b.id))
    }

    @Test func aTakenImpWeCalledHomeMeanwhileIsToldGone() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        let transfer = try await throwImp(imp, from: a, to: b, accepting: false)
        #expect(a.node.callHome(imp.id) == b.id)
        #expect(b.node.accept(transfer))
        #expect(await a.passed()?.outcome == .declined(.other))
        #expect(await until { b.node.visits.visits.isEmpty })
        #expect(a.node.holder(of: imp.id) == nil)
    }

    @Test func aLateTookForAnImpOfOursIsToldGone() async throws {
        let a = try Probe(1) { $0.transferTimeout = 0.2 }, b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let imp = testImp(1)
        let transfer = try await throwImp(imp, from: a, to: b, accepting: false)
        #expect(await a.passed()?.outcome == .declined(.timeout))
        // B only decides afterwards. Its `took` is late: A has called the Imp home.
        #expect(b.node.accept(transfer))
        #expect(await until { b.node.visits.visits.isEmpty })
        #expect(a.node.holder(of: imp.id) == nil)
    }

    @Test func throwsNobodyAnsweredAreCalledHomeAfterARestart() async throws {
        let imp = testImp(1), to = linkDevice(2).id
        var book = LinkBook(device: linkDevice(1).id, seed: linkDevice(1).seed, door: LinkCrypto.randomKey())
        _ = book.away.mint(imp.id, to: to)
        book.passing = [LinkBook.Passing(transfer: UUID(), imp: imp.id, to: to)]
        let a = try Probe(1, storage: LinkMemoryStorage(book))
        #expect(a.node.away.isAway(imp.id))
        await a.start()
        defer { a.node.stop() }
        #expect(!a.node.away.isAway(imp.id) && a.node.away.notices == [AwayLedger.Notice(device: to, imp: imp.id)])
        #expect(try saved(a).passing.isEmpty)
    }

    @Test func aThrowOfOursIsInTheBookUntilItIsAnswered() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let transfer = try await throwImp(testImp(1), from: a, to: b, accepting: false)
        #expect(try saved(a).passing.map(\.transfer) == [transfer])
        b.node.decline(transfer, reason: .other)
        #expect(await a.passed()?.outcome == .declined(.other))
        #expect(try saved(a).passing.isEmpty)
    }

    @Test func aDeviceThatForgetsUsEndsWhatForgettingWouldHave() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let mine = testImp(1), theirs = testImp(2)
        try await throwImp(mine, from: a, to: b)
        try await throwImp(theirs, from: b, to: a)
        #expect(await until { a.node.holder(of: mine.id) == b.id && b.node.holder(of: theirs.id) == a.id })
        a.node.forget(b.id)
        let event = await b.take { if case .forgotten = $0 { return true } else { return false } }
        guard case .forgotten(let id, let result)? = event else { Issue.record("no forgotten event"); return }
        // Our Imp it held is called home; its own was already told `gone` before the goodbye.
        #expect(id == a.id && result.calledHome == [theirs.id])
        #expect(b.node.visits.visits.isEmpty && !b.node.away.isAway(theirs.id) && b.node.links.isEmpty)
    }

    @Test func aConnectionThatSendsTooFastIsClosed() async throws {
        let a = try Probe(1), b = try Probe(2) { $0.frameRate = 1; $0.frameBurst = 30 }
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        for _ in 0..<200 { a.node.send(.ping, to: b.id) }
        #expect(await b.take { if case .disconnected(let id) = $0 { return id == a.id } else { return false } } != nil)
    }

    @Test func aDeviceCannotLeaveMoreThanEightThrowsWaiting() async throws {
        let a = try Probe(1), b = try Probe(2)
        await a.start(); await b.start()
        defer { a.node.stop(); b.node.stop() }
        try await link(a, b)
        let ids = (1...10).compactMap { a.node.pass(testImp($0), entry: entry, to: b.id) }
        #expect(ids.count == 10)
        #expect(await a.passed { $0.transfer == ids[8] }?.outcome == .declined(.full))
        #expect(await a.passed { $0.transfer == ids[9] }?.outcome == .declined(.full))
        #expect(ids.prefix(8).allSatisfy { b.node.canAccept($0) })
        #expect(!b.node.canAccept(ids[8]))
    }
}
