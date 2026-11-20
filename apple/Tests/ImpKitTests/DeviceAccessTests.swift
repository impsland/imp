import Foundation
import Testing
@testable import ImpKit

/// The plugs a linked device can have: one list for the canvas and the sheets, and the rules of plugging.
@Suite struct DeviceAccessTests {
    private let device = UUID()

    private func prefs(limits: [String] = []) -> ImpPreferences {
        var prefs = ImpPreferences()
        prefs.imps = [ImpProfile(name: "Dot", hue: 0.2, favoriteHue: 0.5, personality: "")]
        for id in limits { prefs.deviceToolLimits.set(false, group: id, on: device) }
        return prefs
    }

    @Test func talkAndFilesComesFirstAndFollowsTrustAlone() {
        let prefs = prefs()
        #expect(DeviceAccess.of(peer: device, trusted: true, prefs: prefs).capabilities.first?.id == DeviceAccess.talk)
        #expect(DeviceAccess.of(peer: device, trusted: true, prefs: prefs).capabilities.first?.allowed == true)
        #expect(DeviceAccess.of(peer: device, trusted: false, prefs: prefs).capabilities.first?.allowed == false)
    }

    @Test func theToolsAreThoseAnImpUsesAndEachFollowsItsLimit() throws {
        let base = DeviceAccess.of(peer: device, trusted: true, prefs: prefs())
        let tool = try #require(base.tools.first)
        #expect(base.tools.allSatisfy { $0.allowed }, "nothing is off until it is switched off")
        let limited = DeviceAccess.of(peer: device, trusted: true, prefs: prefs(limits: [tool.id]))
        #expect(limited.tools.first { $0.id == tool.id }?.allowed == false)
        #expect(limited.pluggedIn.contains { $0.id == tool.id } == false)
        #expect(limited.pluggedIn.first?.id == DeviceAccess.talk)
    }

    @Test func nothingIsPluggedInWhileTheDeviceIsNotTrusted() {
        let access = DeviceAccess.of(peer: device, trusted: false, prefs: prefs())
        #expect(access.pluggedIn.isEmpty)
        #expect(!access.isPlugged(DeviceAccess.talk))
    }

    @Test func pluggingAToolWhileNotTrustedTrustsTheDeviceToo() throws {
        let access = DeviceAccess.of(peer: device, trusted: false, prefs: prefs(limits: [DeviceToolLimits.groupID(.personality)]))
        let tool = try #require(access.tools.first)
        let plugged = access.plugging(tool.id, true)
        #expect(plugged.trusted && plugged.capabilities.first?.allowed == true)
        #expect(plugged.isPlugged(tool.id) && plugged.isPlugged(DeviceAccess.talk))
    }

    @Test func unpluggingTalkAndFilesKeepsTheToolLimitsForWhenItIsPluggedBack() throws {
        let base = DeviceAccess.of(peer: device, trusted: true, prefs: prefs())
        let tool = try #require(base.tools.first)
        let limited = base.plugging(tool.id, false)
        let unplugged = limited.plugging(DeviceAccess.talk, false)
        #expect(!unplugged.trusted && unplugged.pluggedIn.isEmpty)
        #expect(unplugged.tools == limited.tools, "the limits stay as they are")
        let back = unplugged.plugging(DeviceAccess.talk, true)
        #expect(back.isPlugged(DeviceAccess.talk) && !back.isPlugged(tool.id) && back.tools.dropFirst().allSatisfy { $0.allowed })
        #expect(unplugged.plugging("nothing", true) == unplugged, "an unknown plug changes nothing")
    }

    @Test func theLimitsAreWrittenForTheDevice() throws {
        let base = DeviceAccess.of(peer: device, trusted: true, prefs: prefs())
        let tool = try #require(base.tools.first)
        let limits = base.plugging(tool.id, false).limits(applying: DeviceToolLimits(), peer: device)
        #expect(limits.limited(on: device) == [tool.id])
        #expect(base.limits(applying: limits, peer: device).limited(on: device).isEmpty)
    }
}
