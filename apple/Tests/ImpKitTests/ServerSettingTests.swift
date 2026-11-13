import Foundation
import Testing
@testable import ImpKit

/// The state behind the Den and Hop cards: the choices, the address and the check.
@Suite struct ServerSettingTests {
    @Test func theChoiceFollowsTheAddress() {
        #expect(ServerSetting(kind: .hop, text: ServerKind.hop.defaultAddress).choice == .imps)
        #expect(ServerSetting(kind: .hop, text: ServerKind.hop.localAddress).choice == .custom)
        #expect(ServerSetting(kind: .den, text: "").choice == .off)
        let custom = ServerSetting(kind: .hop, text: "hop.example.com:4677")
        #expect(custom.choice == .custom && custom.showsAddress)
    }

    @Test func pickingFillsTheAddressAndCustomKeepsWhatWasTyped() {
        var s = ServerSetting(kind: .den, text: ServerKind.den.defaultAddress)
        let off = s.pick(.off)
        #expect(off == "" && s.status == .off && !s.canCheck)
        let imps = s.pick(.imps)
        #expect(imps == ServerKind.den.defaultAddress)
        let custom = s.pick(.custom)
        #expect(custom == "" && s.choice == .custom, "a preset's address is not kept as a custom one")
        s.edit("den.example.com")
        let typed = s.pick(.custom)
        #expect(typed == "den.example.com")
        s.edit(ServerKind.den.defaultAddress)
        #expect(s.choice == .custom, "custom stays picked while typing")
    }

    @Test func theCheckRunsOnceAndAnsweredForTheAddressItWasFor() throws {
        var s = ServerSetting(kind: .hop, text: ServerKind.hop.defaultAddress)
        let address = try #require(s.inUse)
        #expect(s.status == .ready(address) && s.canCheck)
        let started = s.startCheck()
        #expect(started == address)
        let again = s.startCheck()
        #expect(s.status == .checking(address) && !s.canCheck && again == nil)
        s.finishCheck(address, reachable: true)
        #expect(s.status == .reachable(address) && s.canCheck)
        _ = s.startCheck()
        s.finishCheck(address, reachable: false)
        #expect(s.status == .unreachable(address))
    }

    @Test func aChangedAddressDropsTheCheck() throws {
        var s = ServerSetting(kind: .hop, text: ServerKind.hop.defaultAddress)
        let started = s.startCheck()
        let address = try #require(started)
        s.pick(.off)
        s.edit("hop.example.com:4677")
        s.finishCheck(address, reachable: true)
        #expect(s.status == .ready(try #require(s.inUse)), "a late answer for the old address is dropped")
        _ = s.startCheck()
        s.edit("hop.example.com:4677")
        #expect(s.status == .ready("hop.example.com:4677"))
    }

    @Test func aWrongAddressSaysWhy() {
        let s = ServerSetting(kind: .den, text: "not an address at all ://")
        guard case .problem(let sentence) = s.status else { Issue.record("expected a problem"); return }
        #expect(!sentence.isEmpty && !s.canCheck && s.inUse == nil)
    }
}
