import Foundation
import Testing
@testable import ImpKit

@Suite struct ShakeTransferTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let settings = ShakeSettings()

    func imp(_ n: Int, moved: TimeInterval? = nil, touched: TimeInterval? = nil, name: String? = nil) -> ShakeTransfer.Imp {
        ShakeTransfer.Imp(id: id(n), name: name ?? "Imp\(n)",
                          lastMoved: moved.map { now.addingTimeInterval(-$0) }, lastTouched: touched.map { now.addingTimeInterval(-$0) })
    }

    func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")! }

    func peer(_ n: Int, name: String? = nil, linked: Bool = true, connected: Bool = true, viaHop: Bool = false,
              seen: TimeInterval? = nil, mine: Bool = true) -> ShakeTransfer.Peer {
        ShakeTransfer.Peer(id: id(100 + n), name: name ?? "Device\(n)", linked: linked, connected: connected, viaHop: viaHop,
                           lastNearby: seen.map { now.addingTimeInterval(-$0) }, mine: mine)
    }

    func decide(_ imps: [ShakeTransfer.Imp], _ peers: [ShakeTransfer.Peer], side: LinkSide? = nil,
                _ s: ShakeSettings? = nil) -> ShakeTransfer.Decision {
        ShakeTransfer.decide(imps: imps, peers: peers, side: side, settings: s ?? settings, now: now)
    }

    // MARK: Which Imp

    @Test func theImpMovedLastGoes() {
        let picked = ShakeTransfer.pick([imp(1, moved: 300, touched: 5), imp(2, moved: 60, touched: 200), imp(3)])
        #expect(picked?.id == id(2))
    }

    @Test func withoutAMoveTheOneTouchedLastGoes() {
        #expect(ShakeTransfer.pick([imp(1, touched: 90), imp(2, touched: 10), imp(3)])?.id == id(2))
    }

    @Test func withoutAnyHistoryTheSameImpIsPickedEveryTime() {
        let imps = [imp(2, name: "Zed"), imp(1, name: "Ann"), imp(3, name: "Moe")]
        #expect(ShakeTransfer.pick(imps)?.name == "Ann")
        #expect(ShakeTransfer.pick(imps.reversed())?.name == "Ann")
    }

    // MARK: Where

    @Test func oneDeviceNearbySendsAtOnceWithoutAsking() {
        #expect(decide([imp(1, moved: 5)], [peer(1)]) == .send(imp: id(1), to: id(101)))
    }

    @Test func aDeviceOnlyThroughTheServerButSeenNearbyLatelyIsStillSentToWithUndo() {
        #expect(decide([imp(1)], [peer(1, viaHop: true, seen: 120)]) == .send(imp: id(1), to: id(101)))
    }

    @Test func aDeviceFarAwayIsAskedAbout() {
        #expect(decide([imp(1)], [peer(1, viaHop: true)]) == .ask(imp: id(1), choices: [id(101)], why: .farAway))
        #expect(decide([imp(1)], [peer(1, viaHop: true, seen: 3_600)]) == .ask(imp: id(1), choices: [id(101)], why: .farAway))
    }

    @Test func aLinkedDeviceThatIsNotMineIsAskedAboutUnlessTurnedOff() {
        #expect(decide([imp(1)], [peer(1, mine: false)]) == .ask(imp: id(1), choices: [id(101)], why: .friend))
        var s = settings
        s.asksForFriends = false
        #expect(decide([imp(1)], [peer(1, mine: false)], s) == .send(imp: id(1), to: id(101)))
    }

    @Test func aDeviceThatIsNotLinkedOrNotConnectedIsNeverATarget() {
        #expect(decide([imp(1)], [peer(1, linked: false)]) == .nothing(.nobodyAround))
        #expect(decide([imp(1)], [peer(1, connected: false, seen: 1)]) == .nothing(.nobodyAround))
        // Next to a device that is linked, it is the linked one.
        #expect(decide([imp(1)], [peer(1, linked: false), peer(2)]) == .send(imp: id(1), to: id(102)))
    }

    @Test func nearbyBeatsRecentlySeen() {
        #expect(decide([imp(1)], [peer(1, viaHop: true, seen: 30), peer(2)]) == .send(imp: id(1), to: id(102)))
    }

    @Test func severalNearbyAskByDefaultInAStableOrder() {
        let d = decide([imp(1)], [peer(2, name: "Mac"), peer(1, name: "Air")], side: .right)
        #expect(d == .ask(imp: id(1), choices: [id(101), id(102)], why: .severalNearby))
    }

    @Test func leftAndRightPickBetweenTwoWhenTurnedOn() {
        var s = settings
        s.direction = .leftRight
        let peers = [peer(2, name: "Mac"), peer(1, name: "Air")]
        #expect(decide([imp(1)], peers, side: .right, s) == .send(imp: id(1), to: id(101)))
        #expect(decide([imp(1)], peers, side: .left, s) == .send(imp: id(1), to: id(102)))
        // A shake that cannot tell its side asks.
        #expect(decide([imp(1)], peers, side: nil, s) == .ask(imp: id(1), choices: [id(101), id(102)], why: .severalNearby))
        // Three or more cannot be told apart by two sides.
        let three = peers + [peer(3, name: "Zoo")]
        #expect(decide([imp(1)], three, side: .right, s) == .ask(imp: id(1), choices: [id(101), id(102), id(103)], why: .severalNearby))
    }

    @Test func offOrNothingToSendDoesNothing() {
        var s = settings
        s.enabled = false
        #expect(decide([imp(1)], [peer(1)], s) == .nothing(.off))
        #expect(decide([], [peer(1)]) == .nothing(.noImps))
        #expect(decide([imp(1)], []) == .nothing(.nobodyAround))
    }

    // MARK: Settings and the shake

    @Test func settingsRoundTripAndDefaultToOn() throws {
        let suite = "ShakeSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ShakeSettings(defaults: defaults) == ShakeSettings())
        var s = ShakeSettings()
        s.enabled = false; s.sensitivity = .firm; s.direction = .leftRight; s.asksForFriends = false
        s.save(to: defaults)
        #expect(ShakeSettings(defaults: defaults) == s)
    }

    @Test func aShakeSaysWhichWayItStarted() {
        var d = JoltDetector(threshold: 1.5, window: 0.45, shakeCount: 4, cooldown: 1)
        var t = 0.0, sign = -1.0, event: JoltDetector.Event?
        while event == nil, t < 1 {
            event = d.feed(x: 2.4 * sign, at: t)
            sign = -sign
            t += 0.08
        }
        #expect(event == .shaken)
        #expect(d.shakeStart == .left)
    }

    @Test func firmNeedsHarderPushesThanGentle() {
        #expect(ShakeSettings.Sensitivity.gentle.threshold < ShakeSettings.Sensitivity.normal.threshold)
        #expect(ShakeSettings.Sensitivity.normal.threshold < ShakeSettings.Sensitivity.firm.threshold)
    }
}
