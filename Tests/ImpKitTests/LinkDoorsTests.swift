import Foundation
import Testing
@testable import ImpKit

@Suite struct LinkDoorsTests {
    let d1 = linkDevice(1).id, d2 = linkDevice(2).id, d3 = linkDevice(3).id, d4 = linkDevice(4).id

    @Test func atHomeEitherSideLeadsToEveryone() {
        for side in [LinkSide.left, .right] {
            #expect(LinkDoors.reach(side: side, travel: .home, connected: [d3, d1, d2]) == [d1, d2, d3])
        }
    }

    @Test func theOrderIsStableWhateverTheConnectionOrder() {
        let a = LinkDoors.reach(side: .left, travel: .home, connected: [d4, d2, d3])
        #expect(a == LinkDoors.reach(side: .left, travel: .home, connected: [d3, d4, d2]))
        #expect(a == LinkDoors.reach(side: .left, travel: .home, connected: [d2, d2, d3, d4, d4]))
        #expect(a == a.sorted { $0.uuidString < $1.uuidString })
    }

    @Test func aVisitGoesBackTheWayItCameAndOnTheOtherWay() {
        let travel = LinkTravel.visit(side: .right, from: d1)
        let connected = [d1, d2, d3]
        #expect(LinkDoors.reach(side: .right, travel: travel, connected: connected) == [d1])
        #expect(LinkDoors.reach(side: .left, travel: travel, connected: connected) == [d2, d3])
        #expect(LinkDoors.door(side: .right, height: 0.9, travel: travel, connected: connected) == .to(d1))
        #expect(LinkDoors.door(side: .left, height: 0.1, travel: travel, connected: connected) == .to(d2))
        #expect(LinkDoors.door(side: .left, height: 0.9, travel: travel, connected: connected) == .to(d3))
    }

    @Test func theForwardSideNeverLeadsBack() {
        for entry in [LinkSide.left, .right] {
            let travel = LinkTravel.visit(side: entry, from: d1)
            let forward = LinkDoors.reach(side: entry.opposite, travel: travel, connected: [d1, d2, d3])
            #expect(!forward.contains(d1) && forward == [d2, d3])
        }
    }

    @Test func heightPicksTheBand() {
        let connected = [d1, d2, d3, d4]
        func pick(_ h: Double) -> LinkDoors.Outcome { LinkDoors.door(side: .left, height: h, travel: .home, connected: connected) }
        #expect(pick(0) == .to(d1) && pick(0.24) == .to(d1) && pick(0.25) == .to(d2))
        #expect(pick(0.5) == .to(d3) && pick(0.74) == .to(d3) && pick(0.75) == .to(d4) && pick(1) == .to(d4))
        // Out of range or nonsense still lands somewhere sensible.
        #expect(pick(-4) == .to(d1) && pick(9) == .to(d4))
        #expect(pick(.nan) == .to(d3) && pick(.infinity) == .to(d3))
    }

    @Test func bandsAreEqualFromTopToBottom() {
        let bands = LinkDoors.bands(side: .right, travel: .home, connected: [d1, d2, d3])
        #expect(bands.map(\.device) == [d1, d2, d3])
        #expect(bands.first?.top == 0 && bands.last?.bottom == 1)
        for (a, b) in zip(bands, bands.dropFirst()) { #expect(a.bottom == b.top) }
        #expect(abs((bands[0].bottom - bands[0].top) - 1.0 / 3) < 1e-9)
        #expect(LinkDoors.bands(side: .right, travel: .home, connected: []).isEmpty)
    }

    @Test func aSideThatLeadsNowhereBounces() {
        #expect(LinkDoors.door(side: .left, height: 0.5, travel: .home, connected: []) == .bounce(.nobodyConnected))
        let back = LinkTravel.visit(side: .left, from: d1)
        // The way back is closed: its device isn't connected, but others are.
        #expect(LinkDoors.door(side: .left, height: 0.5, travel: back, connected: [d2]) == .bounce(.wayBackIsClosed))
        // Only the device it came from is connected: the other side leads nowhere.
        #expect(LinkDoors.door(side: .right, height: 0.5, travel: back, connected: [d1]) == .bounce(.nowhereElse))
        #expect(LinkDoors.door(side: .right, height: 0.5, travel: back, connected: []) == .bounce(.nobodyConnected))
    }
}
