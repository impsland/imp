import Foundation
import Testing
@testable import ImpKit

/// Devices and their books, joined by links, with no network: the same pure pieces the node uses
/// (doors, visits, the ledger) moved by the same steps as `LinkNode.pass`, `accept` and the claims.
private final class Sim {
    final class Device {
        let identity: LinkIdentity
        var id: UUID { identity.id }
        var links: Set<UUID> = []
        var visits = Visits()
        var away = AwayLedger()
        /// Imps of this device whose body is here.
        var here: Set<UUID> = []
        let door = LinkCrypto.randomKey()
        init(_ identity: LinkIdentity) { self.identity = identity }
        var card: LinkCard { LinkCard(device: identity.device, door: door, routes: .none) }
    }

    var devices: [UUID: Device] = [:]
    /// Imps in play: home and looks.
    var imps: [UUID: (home: UUID, look: LinkImp)] = [:]

    @discardableResult
    func add(_ n: Int) -> Device {
        let d = Device(linkDevice(n))
        devices[d.id] = d
        return d
    }

    func device(_ n: Int) -> Device { devices[linkDevice(n).id]! }

    func link(_ a: Int, _ b: Int) {
        device(a).links.insert(device(b).id)
        device(b).links.insert(device(a).id)
    }

    func hatch(_ n: Int, on d: Int) {
        imps[testImp(n).id] = (device(d).id, testImp(n))
        device(d).here.insert(testImp(n).id)
    }

    /// Where an Imp on `d` goes when thrown off `side` at `height`.
    func door(of imp: Int, on d: Int, side: LinkSide, height: Double = 0.5) -> LinkDoors.Outcome {
        let dev = device(d)
        return LinkDoors.door(side: side, height: height, travel: dev.visits.travel(of: testImp(imp).id), connected: Array(dev.links))
    }

    /// Throws an Imp off a side. Returns the device it landed on, or nil if it bounced.
    @discardableResult
    func `throw`(_ imp: Int, from d: Int, side: LinkSide, height: Double = 0.5) -> UUID? {
        let id = testImp(imp).id
        let from = device(d)
        guard case .to(let target) = door(of: imp, on: d, side: side, height: height), let to = devices[target] else { return nil }
        // What `LinkNode.pass` sends.
        var home: LinkCard?, ticket: Data?
        if let visit = from.visits.visit(of: id) {
            if visit.home.id != to.id { home = visit.home; ticket = visit.ticket }
        } else {
            home = from.card
            ticket = from.away.mint(id, to: to.id)
        }
        // What `LinkNode.accept` does, and then the claim at the home.
        let entry = LinkEntry.after(exit: side, height: height, speed: 0)
        if let home, let ticket {
            to.visits.arrive(testImp(imp), entry: entry, from: from.id, home: home, ticket: ticket)
        } else {
            to.away.cameHome(id)
        }
        from.visits.leave(id)
        from.here.remove(id)
        to.here.insert(id)
        if let home, let ticket { claim(id, ticket: ticket, by: to, at: devices[home.id]!) }
        return to.id
    }

    /// A holder claims an Imp at its home (a link or a visitor connection, it makes no difference).
    func claim(_ imp: UUID, ticket: Data, by holder: Device, at home: Device) {
        switch home.away.claim(imp, ticket: ticket, by: holder.id) {
        case .granted(let fresh, _):
            holder.visits.rotate(imp, ticket: fresh)
            // The previous holder is told `gone` and lets go of a body it still has.
            for (_, other) in devices where other !== holder {
                for gone in home.away.takeNotices(for: other.id) where other.visits.visit(of: gone)?.home.id == home.id {
                    other.visits.leave(gone)
                    other.here.remove(gone)
                }
            }
        case .refused:
            // `gone`: the body here has to go.
            holder.visits.leave(imp)
            holder.here.remove(imp)
        }
    }

    func ids(_ ns: [Int]) -> Set<UUID> { Set(ns.map { testImp($0).id }) }
}

@Suite struct LinkScenarioTests {
    @Test func impsTravelAcrossFourDevices() throws {
        let sim = Sim()
        for n in 1...4 { sim.add(n) }
        let d1 = sim.device(1), d2 = sim.device(2), d3 = sim.device(3), d4 = sim.device(4)
        for n in 1...4 { sim.hatch(n, on: 1) }
        sim.link(1, 2)

        // Device 1 throws Imps 2 and 3 off its left side and Imp 4 off its right, all to device 2.
        #expect(sim.throw(2, from: 1, side: .left, height: 0.2) == d2.id)
        #expect(sim.throw(3, from: 1, side: .left, height: 0.8) == d2.id)
        #expect(sim.throw(4, from: 1, side: .right, height: 0.5) == d2.id)
        #expect(d1.here == sim.ids([1]))
        #expect(d2.here == sim.ids([2, 3, 4]))
        #expect(d1.away.holder(of: testImp(2).id) == d2.id && d1.away.entries.count == 3)
        // Imps 2 and 3 came in by the right side of device 2, Imp 4 by its left.
        #expect(d2.visits.travel(of: testImp(2).id) == .visit(side: .right, from: d1.id))
        #expect(d2.visits.travel(of: testImp(4).id) == .visit(side: .left, from: d1.id))
        // Each claimed at its home: the tickets are already rotated.
        #expect(d1.away.entries.allSatisfy { $0.generation == 2 })
        for n in 2...4 {
            let visit = try #require(d2.visits.visit(of: testImp(n).id))
            #expect(LinkCrypto.matches(ticket: visit.ticket, hash: d1.away.entry(of: testImp(n).id)!.ticket))
        }

        // Device 2 also links with device 3, and device 4 links with device 3.
        sim.link(2, 3)
        sim.link(4, 3)

        // Thrown back off the side it came in by, an Imp can only go to where it came from.
        #expect(sim.door(of: 3, on: 2, side: .right) == .to(d1.id))
        #expect(sim.door(of: 4, on: 2, side: .left) == .to(d1.id))
        // Its forward side leads to device 3 and never back to device 1.
        #expect(sim.door(of: 3, on: 2, side: .left, height: 0) == .to(d3.id))
        #expect(sim.door(of: 3, on: 2, side: .left, height: 1) == .to(d3.id))
        #expect(sim.door(of: 4, on: 2, side: .right, height: 0.3) == .to(d3.id))
        // Imp 2, at home on neither side... it came by the right side too, so left is forward as well.
        #expect(sim.door(of: 2, on: 2, side: .left) == .to(d3.id))

        // Device 2 passes Imps 3 and 4 on to device 3, each through its forward side.
        #expect(sim.throw(3, from: 2, side: .left) == d3.id)
        #expect(sim.throw(4, from: 2, side: .right) == d3.id)
        #expect(d2.here == sim.ids([2]) && d3.here == sim.ids([3, 4]))
        #expect(d1.away.holder(of: testImp(3).id) == d3.id && d1.away.holder(of: testImp(4).id) == d3.id)
        // Device 3 got them from device 2, which entered on its right and left sides respectively.
        #expect(d3.visits.travel(of: testImp(3).id) == .visit(side: .right, from: d2.id))
        #expect(d3.visits.travel(of: testImp(4).id) == .visit(side: .left, from: d2.id))
        // Device 3 isn't linked to device 1, and still holds the home's card to reach it.
        #expect(!d3.links.contains(d1.id) && d3.visits.visit(of: testImp(3).id)?.home.id == d1.id)

        // Device 3 passes Imp 4 on to device 4, through the side that leads on (not back to device 2).
        #expect(sim.door(of: 4, on: 3, side: .left) == .to(d2.id))
        #expect(sim.throw(4, from: 3, side: .right) == d4.id)
        #expect(d3.here == sim.ids([3]) && d4.here == sim.ids([4]))

        // Everyone ends with one Imp; all of them think on device 1.
        for dev in [d1, d2, d3, d4] { #expect(dev.here.count == 1) }
        for n in 1...4 { #expect(sim.imps[testImp(n).id]?.home == d1.id) }
        #expect(d1.away.holder(of: testImp(2).id) == d2.id)
        #expect(d1.away.holder(of: testImp(3).id) == d3.id)
        #expect(d1.away.holder(of: testImp(4).id) == d4.id)
        #expect(d1.away.isAway(testImp(1).id) == false)

        // Devices 3 and 4 reach device 1 as visitors with rotated tickets: each holds the current one.
        for (dev, n) in [(d2, 2), (d3, 3), (d4, 4)] {
            let visit = try #require(dev.visits.visit(of: testImp(n).id))
            #expect(LinkCrypto.matches(ticket: visit.ticket, hash: d1.away.entry(of: testImp(n).id)!.ticket))
            #expect(visit.home.id == d1.id)
            #expect(dev.visits.claims(at: d1.identity.device).map(\.imp) == [testImp(n).id])
        }
        #expect(d1.away.entry(of: testImp(4).id)?.generation == 4)
        #expect(d1.away.entry(of: testImp(3).id)?.generation == 3)
        // The home answers only the holder.
        #expect(d1.away.authorises(d4.id, for: testImp(4).id) && !d1.away.authorises(d3.id, for: testImp(4).id))
        #expect(!d1.away.authorises(d2.id, for: testImp(3).id))
        // Nobody has anything left to hear.
        for dev in [d2, d3, d4] { #expect(d1.away.takeNotices(for: dev.id).isEmpty) }
    }

    @Test func anImpThrownHomeIsHomeAndItsTicketsDie() throws {
        let sim = Sim()
        for n in 1...3 { sim.add(n) }
        sim.link(1, 2); sim.link(2, 3)
        sim.hatch(1, on: 1)
        let d1 = sim.device(1), d2 = sim.device(2), d3 = sim.device(3)
        #expect(sim.throw(1, from: 1, side: .left) == d2.id)
        #expect(sim.throw(1, from: 2, side: .left) == d3.id)
        let stale = try #require(d3.visits.visit(of: testImp(1).id)?.ticket)
        // Back the way it came, twice: it is home when it reaches device 1, and free to leave by either side.
        #expect(sim.throw(1, from: 3, side: .right) == d2.id)
        #expect(sim.door(of: 1, on: 2, side: .right) == .to(d1.id))
        #expect(sim.throw(1, from: 2, side: .right) == d1.id)
        #expect(d1.here == sim.ids([1]) && d1.visits.visits.isEmpty && !d1.away.isAway(testImp(1).id))
        #expect(sim.door(of: 1, on: 1, side: .left) == .to(d2.id) && sim.door(of: 1, on: 1, side: .right) == .to(d2.id))
        #expect(d1.away.claim(testImp(1).id, ticket: stale, by: d3.id) == .refused)
    }

    @Test func aLateClaimWithAnOldTicketMakesTheBodyGo() throws {
        let sim = Sim()
        for n in 1...3 { sim.add(n) }
        sim.link(1, 2); sim.link(1, 3)
        sim.hatch(1, on: 1)
        let d1 = sim.device(1), d2 = sim.device(2), d3 = sim.device(3)
        // Thrown to 2, then called home, then thrown to 3: whatever 2 still believes is dead.
        #expect(sim.throw(1, from: 1, side: .left, height: 0) == d2.id)
        let old = try #require(d2.visits.visit(of: testImp(1).id)?.ticket)
        #expect(d1.away.callHome(testImp(1).id) == d2.id)
        d1.here.insert(testImp(1).id)
        #expect(sim.throw(1, from: 1, side: .left, height: 1) == d3.id)
        sim.claim(testImp(1).id, ticket: old, by: d2, at: d1)
        #expect(d2.visits.visit(of: testImp(1).id) == nil)
        #expect(d1.away.holder(of: testImp(1).id) == d3.id)
    }
}
