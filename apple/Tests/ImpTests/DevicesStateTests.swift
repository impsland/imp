import Foundation
import ImpKit
import Testing
@testable import Imp

/// The state behind the Devices page and the Link a device sheet: the device list and reading a code.
@Suite struct DevicesStateTests {
    private func peer(_ name: String, _ reach: DeviceLink.Peer.Reach, kind: LinkKind = .phone) -> DeviceLink.Peer {
        DeviceLink.Peer(id: UUID(), name: name, kind: kind, reach: reach, imps: [])
    }

    /// A real code, as another device would show it.
    private var code: String? {
        LinkInvite(device: LinkDevice(id: UUID(), name: "Mac", kind: .mac, key: Data(count: 32)),
                   door: Data(count: 32), invite: Data(count: 32), routes: LinkRoutes(hosts: ["mac.local"]))?.url.absoluteString
    }

    @Test func devicesAreListedByNameAndSayHowTheyAreReached() {
        let list = LinkedDevices.sorted([peer("zed", .away), peer("Anna's iPhone", .direct), peer("Mac mini", .viaServer, kind: .mac)])
        #expect(list.map(\.name) == ["Anna's iPhone", "Mac mini", "zed"])
        #expect(LinkedDevices.reach(list[0], hop: nil).connected)
        #expect(LinkedDevices.reach(list[1], hop: HopServer("hop.example.com:4677")).text.contains("hop.example.com"))
        #expect(!LinkedDevices.reach(list[2], hop: nil).connected)
        #expect(LinkedDevices.symbol(.mac) != LinkedDevices.symbol(.phone))
    }

    @Test func theDeviceThatJustLinkedIsNamed() {
        let old = peer("Old", .direct), new = peer("New", .direct)
        #expect(LinkedDevices.newcomer([old], before: [old.id]) == nil)
        #expect(LinkedDevices.newcomer([old, new], before: [old.id]) == "New")
    }

    @Test func readingACodeGoesFromEmptyToLinked() throws {
        let code = try #require(code)
        var join = LinkJoin()
        #expect(join.status == .empty && !join.canLink)
        join.text = "hello"
        #expect(join.status == .notALink && !join.canLink)
        join.text = code
        #expect(join.status == .ready && join.canLink)
        join.start()
        #expect(join.status == .joining && !join.canLink && join.isLocked)
        let seen = join.found(code)
        #expect(seen == nil, "the camera is ignored while linking")
        join.finish(linked: "Mac")
        #expect(join.status == .linked("Mac") && !join.canLink && join.isLocked)
    }

    @Test func aFailedLinkSaysWhyAndCanBeTriedAgain() throws {
        var join = LinkJoin()
        join.text = try #require(code)
        join.start()
        join.finish(failed: "Nobody answered.")
        #expect(join.status == .failed("Nobody answered.") && join.canLink && !join.isLocked)
    }

    @Test func theCameraOnlyTakesImpCodesAndPastingTakesTextOrAPicture() throws {
        let code = try #require(code)
        var join = LinkJoin()
        let other = join.found("https://example.com")
        #expect(other == nil && join.text.isEmpty)
        let ours = join.found(code)
        #expect(ours != nil && join.text == code)
        var pasted = LinkJoin()
        pasted.paste(text: "  \(code) \n", codes: [])
        #expect(pasted.text == code)
        var picture = LinkJoin()
        picture.paste(text: nil, codes: ["nope", code])
        #expect(picture.text == code)
        var nothing = LinkJoin()
        nothing.paste(text: " ", codes: ["nope"])
        if case .failed = nothing.status {} else { Issue.record("an empty paste says so") }
    }
}
