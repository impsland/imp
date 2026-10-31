// Live Hop (opt-in): Link nodes whose only route to each other is a running Hop, over TCP.
//   cd server && cargo run -p hop &                      (listens on HOP_ADDR, 0.0.0.0:4677 by default)
//   IMP_HOP=127.0.0.1:4677 swift test --skip-build --filter HopLiveTests
// The nodes have no host names and no Bonjour, so a guest can only reach its host through the Hop.
// The Hop limits each address to 30 new connections a minute by default; repeated runs against one Hop need
// HOP_PER_IP_PER_MINUTE raised (for example 100000 on a local test Hop).
// Everything waits for events with a timeout, never for a fixed time.

import Foundation
import Testing
@testable import ImpKit

/// A node and what it told the app, in order.
@MainActor
private final class HopNode {
    let node: LinkNode
    private(set) var events: [LinkNode.Event] = []
    var id: UUID { node.device.id }

    init(_ n: Int, kind: LinkKind) throws {
        var options = LinkNode.Options()
        options.port = nil
        options.bonjour = false
        options.watchesNetwork = false
        options.hosts = []          // nil would mean this Mac's LAN addresses, which would bypass the Hop
        options.tick = 0.05
        options.visitorGrace = 0.6
        options.handshakeTimeout = 10
        options.transferTimeout = 5
        options.retryStart = 0.1
        options.retryLongest = 0.4
        options.joinTimeout = 12
        node = try LinkNode(name: "Hop device \(n)", kind: kind, id: linkDevice(n).id, storage: LinkMemoryStorage(), options: options)
        node.onEvent = { [weak self] in self?.events.append($0) }
    }

    /// Starts the node and gives it the Hop to wait at.
    func start(hop: HopAddress) async {
        await node.start()
        node.setServer(hop)
    }

    /// The first event not yet taken that `match` likes, waiting up to `seconds` for it.
    @discardableResult
    func take(_ seconds: Double = 10, _ match: (LinkNode.Event) -> Bool) async -> LinkNode.Event? {
        let end = Date().addingTimeInterval(seconds)
        while true {
            if let i = events.firstIndex(where: match) { return events.remove(at: i) }
            if Date() > end { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func passed(_ seconds: Double = 10) async -> LinkNode.Passed? {
        let event = await take(seconds) { if case .passed = $0 { return true } else { return false } }
        if case .passed(let p)? = event { return p }
        return nil
    }

    func connected(to other: HopNode, as standing: LinkStanding) async -> Bool {
        await until { self.node.standing(of: other.id) == standing }
    }
}

@MainActor
private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private let hopEntry = LinkEntry(side: .right, height: 0.5, speed: 900)

/// `from` throws `imp` to `to` through the Hop, which takes it. Returns the transfer.
@MainActor
@discardableResult
private func throwImp(_ imp: LinkImp, from: HopNode, to: HopNode) async throws -> UUID {
    let transfer = try #require(from.node.pass(imp, entry: hopEntry, to: to.id))
    let arrived = await to.take { if case .message(.pass(let t, _, _, _, _), _) = $0 { return t == transfer } else { return false } }
    #expect(arrived != nil, "the thrown Imp never reached \(to.node.device.name) through the Hop")
    #expect(to.node.accept(transfer))
    return transfer
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IMP_HOP"] != nil), .serialized) struct HopLiveTests {
    private var hop: HopAddress {
        get throws { try #require(HopAddress(ProcessInfo.processInfo.environment["IMP_HOP"] ?? "")) }
    }

    /// `guest` scans a fresh code of `host`, over the Hop; both end up connected as peers.
    private func link(_ host: HopNode, _ guest: HopNode) async throws {
        let device = try await guest.node.join(host.node.invite())
        #expect(device.id == host.id)
        #expect(await guest.connected(to: host, as: .peer))
        #expect(await host.connected(to: guest, as: .peer))
        #expect(guest.node.isThroughHop(host.id), "the guest reached its host some other way than the Hop")
    }

    @Test func aGuestJoinsItsHostThroughTheHopAndAnImpPasses() async throws {
        let hop = try hop
        let host = try HopNode(1, kind: .mac), guest = try HopNode(2, kind: .phone)
        await host.start(hop: hop); await guest.start(hop: hop)
        defer { host.node.stop(); guest.node.stop() }
        try await link(host, guest)

        let imp = testImp(1)
        let transfer = try await throwImp(imp, from: host, to: guest)
        let result = await host.passed()
        #expect(result == LinkNode.Passed(transfer: transfer, imp: imp.id, to: guest.id, kind: .pass, outcome: .took))
        #expect(await until { guest.node.visits.visit(of: imp.id)?.home.id == host.id })

        // Thrown back over the same Hop, it is home again.
        try await throwImp(imp, from: guest, to: host)
        #expect(await guest.passed()?.outcome == .took)
    }

    @Test func aVisitorClaimsATicketThroughTheHop() async throws {
        let hop = try hop
        let a = try HopNode(1, kind: .mac), b = try HopNode(2, kind: .phone), c = try HopNode(3, kind: .phone)
        await a.start(hop: hop); await b.start(hop: hop); await c.start(hop: hop)
        defer { a.node.stop(); b.node.stop(); c.node.stop() }
        try await link(a, b)
        try await link(c, b)

        // A's Imp goes to B, then B passes it on to C: C holds it, and A is its home.
        let imp = testImp(1)
        try await throwImp(imp, from: a, to: b)
        #expect(await a.passed()?.outcome == .took)
        #expect(await until { a.node.away.entry(of: imp.id)?.generation == 2 })
        try await throwImp(imp, from: b, to: c)
        #expect(await b.passed()?.outcome == .took)

        // C reaches A as a visitor, over the Hop, and claims: A rotates the ticket and C is the holder.
        #expect(await a.take { if case .connected(let d, .visitor) = $0 { return d.id == c.id } else { return false } } != nil)
        #expect(await until { a.node.holder(of: imp.id) == c.id && a.node.away.entry(of: imp.id)?.generation == 3 })
        #expect(await until {
            guard let ticket = c.node.visits.visit(of: imp.id)?.ticket, let hash = a.node.away.entry(of: imp.id)?.ticket else { return false }
            return LinkCrypto.matches(ticket: ticket, hash: hash)
        })
    }

    @Test func aGuestWithAWrongDoorIsTurnedAwayByTheHop() async throws {
        let hop = try hop
        let host = try HopNode(1, kind: .mac), guest = try HopNode(2, kind: .phone), other = try HopNode(3, kind: .phone)
        await host.start(hop: hop); await guest.start(hop: hop); await other.start(hop: hop)
        defer { host.node.stop(); guest.node.stop(); other.node.stop() }

        // The gate is derived from the door key, so a wrong door can't get past the Hop.
        var wrong = host.node.invite()
        wrong.door = LinkCrypto.randomKey()
        await #expect(throws: LinkNode.JoinError.self) { try await guest.node.join(wrong) }
        // The Hop itself refused the guest (its gate isn't the host's), so the guest says so.
        #expect(await guest.take { if case .problem(.hop) = $0 { return true } else { return false } } != nil)
        #expect(!guest.node.isConnected(host.id))
        #expect(!host.node.isConnected(guest.id))

        // The host kept waiting: the right door still gets through.
        try await link(host, other)
    }
}
