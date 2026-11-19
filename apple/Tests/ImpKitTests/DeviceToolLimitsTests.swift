import Foundation
import Testing
@testable import ImpKit

@Suite struct DeviceToolLimitsTests {
    private let phone = UUID(), studio = UUID()

    @Test func nothingIsOffUntilSomeoneSwitchesItOff() {
        let limits = DeviceToolLimits()
        #expect(limits.isAllowed(group: DeviceToolLimits.groupID(.computer), on: phone))
        #expect(!limits.hasLimits(on: phone))
    }

    @Test func limitsAreSetPerDevice() {
        var limits = DeviceToolLimits()
        let computer = DeviceToolLimits.groupID(.computer)
        limits.set(false, group: computer, on: phone)
        #expect(!limits.isAllowed(group: computer, on: phone))
        #expect(limits.isAllowed(group: computer, on: studio))
        limits.set(true, group: computer, on: phone)
        #expect(limits.isAllowed(group: computer, on: phone))
        // Nothing off: nothing stored.
        #expect(limits == DeviceToolLimits())
    }

    @Test func forgettingDropsTheLimits() {
        var limits = DeviceToolLimits()
        limits.set(false, group: DeviceToolLimits.commands, on: phone)
        limits.set(false, group: DeviceToolLimits.commands, on: studio)
        limits.forget(device: phone)
        #expect(!limits.hasLimits(on: phone) && limits.hasLimits(on: studio))
        limits.forgetAll()
        #expect(limits == DeviceToolLimits())
    }

    @Test func theProfileLosesGroupsCommandsAndServersSwitchedOff() {
        let files = UUID(), mail = UUID()
        var imp = ImpProfile(name: "Pip", hue: 0.2, favoriteHue: 0.5, personality: "")
        imp.servers = [files, mail]
        imp.setUses(.computer, true)
        var limits = DeviceToolLimits()
        limits.set(false, group: DeviceToolLimits.groupID(.computer), on: phone)
        limits.set(false, group: DeviceToolLimits.groupID(.senses), on: phone)
        limits.set(false, group: DeviceToolLimits.commands, on: phone)
        limits.set(false, group: DeviceToolLimits.groupID(server: mail), on: phone)

        let limited = limits.profile(imp, limitedOn: phone)
        #expect(!limited.uses(.computer) && !limited.uses(.senses) && limited.uses(.personality))
        #expect(!limited.usesShell)
        #expect(limited.servers == [files])
        // Other devices and the original are untouched, and a profile is not rebuilt without limits.
        #expect(limits.profile(imp, limitedOn: studio) == imp)
        #expect(imp.uses(.computer) && imp.usesShell && imp.servers == [files, mail])
    }

    @Test func aDeviceThatIsNotMineGetsNoTools() {
        let imp = ImpProfile(name: "Pip", hue: 0.2, favoriteHue: 0.5, personality: "")
        var limits = DeviceToolLimits()
        limits.set(false, group: DeviceToolLimits.groupID(.senses), on: phone)
        #expect(AskOrigin(device: phone, name: "Phone", trusted: false).profile(imp, limits: limits) == nil)
        let mine = AskOrigin(device: phone, name: "Phone", trusted: true).profile(imp, limits: limits)
        #expect(mine?.uses(.senses) == false && mine?.uses(.personality) == true)
    }

    @Test func limitsSurviveSavingAndOldSettingsLoad() throws {
        var prefs = ImpPreferences.withWaitingImp()
        prefs.deviceToolLimits.set(false, group: DeviceToolLimits.commands, on: phone)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(!back.deviceToolLimits.isAllowed(group: DeviceToolLimits.commands, on: phone))
        let plain = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(ImpPreferences.withWaitingImp()))
        #expect(plain.deviceToolLimits == DeviceToolLimits())
    }
}
