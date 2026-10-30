import Foundation
import Testing
@testable import ImpKit

@Suite struct TriggerTests {
    @Test func batteryGoesOffOnceWhenItCrossesTheLine() {
        let t = Trigger(.battery, number: 20)
        #expect(t.matches(.battery(from: 21, to: 19)))
        #expect(t.matches(.battery(from: 20, to: 19)))
        #expect(!t.matches(.battery(from: 19, to: 18)), "already below: no new alarm")
        #expect(!t.matches(.battery(from: 18, to: 25)), "charging up never counts")
    }

    @Test func appsMatchByNameOrBundleID() {
        #expect(Trigger(.app, text: "safari").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
        #expect(Trigger(.app, text: "com.apple.Safari").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
        #expect(Trigger(.app, text: "").matches(.app(name: "Notes", bundleID: "com.apple.Notes")), "empty: any app")
        #expect(!Trigger(.app, text: "Chrome").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
    }

    @Test func websitesMatchPartOfTheAddress() {
        let amazon = Trigger(.website, text: "amazon.com")
        #expect(amazon.matches(.page(url: "https://www.amazon.com/dp/B0", title: "")))
        #expect(Trigger(.website, text: "https://amazon.com").matches(.page(url: "https://www.amazon.com/", title: "")))
        #expect(!amazon.matches(.page(url: "https://example.com/?q=amazon", title: "")))
        #expect(!amazon.matches(.app(name: "Amazon", bundleID: "")))
    }

    @Test func clockTriggers() {
        #expect(Trigger(.time, number: 9 * 60 + 5).matches(.minute(ofDay: 545, absolute: 1)))
        #expect(Trigger(.every, number: 30).matches(.minute(ofDay: 0, absolute: 90)))
        #expect(!Trigger(.every, number: 30).matches(.minute(ofDay: 0, absolute: 91)))
        #expect(Trigger.minuteOfDay(parsing: "21:30") == 1290)
        #expect(Trigger.minuteOfDay(parsing: "9pm") == 1260)
        #expect(Trigger.minuteOfDay(parsing: "12am") == 0)
        #expect(Trigger.minuteOfDay(parsing: " 12am ") == 0 && Trigger.minuteOfDay(parsing: "13 am") == nil)
        #expect(Trigger.minuteOfDay(parsing: "7:15 am") == 435)
        #expect(Trigger.minuteOfDay(parsing: "25:00") == nil && Trigger.minuteOfDay(parsing: "soon") == nil)
    }

    @Test func conditionsHoldInState() {
        var state = MacState(battery: 15, charging: false, frontApp: "Safari", frontAppID: "com.apple.Safari",
                             page: "https://amazon.com/cart", cpu: 40, minuteOfDay: 23 * 60)
        #expect(Trigger(.battery, number: 20).holds(in: state))
        #expect(Trigger(.charger, flag: false).holds(in: state))
        #expect(Trigger(.app, text: "Safari").holds(in: state))
        #expect(Trigger(.website, text: "amazon").holds(in: state))
        #expect(!Trigger(.busy, number: 80).holds(in: state))
        #expect(Trigger(.hours, number: 22 * 60, until: 7 * 60).holds(in: state), "a window across midnight")
        state.minuteOfDay = 12 * 60
        #expect(!Trigger(.hours, number: 22 * 60, until: 7 * 60).holds(in: state))
        #expect(!Trigger(.wake).holds(in: state), "an event is never a state")
        #expect(!Trigger(.battery, number: 20).holds(in: MacState()), "no battery: doesn't hold")
    }

    @Test func aShortcutFiresOnlyWhenEveryConditionHolds() {
        let s = Shortcut(name: "Stop shopping", prompt: "Stop me", usesClipboard: false,
                         trigger: Trigger(.website, text: "amazon"), conditions: [Trigger(.battery, number: 30)])
        let visit = MacEvent.page(url: "https://amazon.com", title: "Amazon")
        #expect(s.fires(on: visit, in: MacState(battery: 10)))
        #expect(!s.fires(on: visit, in: MacState(battery: 80)))
        var off = s
        off.isEnabled = false
        #expect(!off.fires(on: visit, in: MacState(battery: 10)))
        let keys = Shortcut(name: "K", prompt: "x", trigger: .keys)
        #expect(!keys.fires(on: .wake, in: MacState()), "keys and clicks aren't Mac events")
    }

    @Test func shortcutsSavedBeforeTriggersAreKeysThatAsk() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"Translate","isEnabled":true,"prompt":"Into French","hotkey":{"keyCode":17,"modifiers":4352}}"#
        let s = try JSONDecoder().decode(Shortcut.self, from: Data(old.utf8))
        #expect(s.trigger == .keys && s.command == .ask && s.conditions.isEmpty && s.keys != nil)
        var clicked = s
        clicked.trigger = .clicks(2)
        #expect(clicked.keys == nil, "keys only listen while they're the trigger")
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(clicked))
        #expect(back == clicked)
    }
}

@Suite struct ClickTriggerTests {
    @Test func freshSettingsClickToTypeAndDoubleClickForSettings() {
        let p = ImpPreferences()
        let imp = p.imps[0].id
        #expect(p.clickShortcut(1, on: imp, in: nil)?.command == .type)
        #expect(p.clickShortcut(2, on: imp, in: nil)?.command == .settings)
        #expect(p.clickShortcut(3, on: imp, in: nil) == nil)
        #expect(p.mostClicks(on: imp) == 2)
    }

    @Test func olderSettingsKeepWhatClicksDid() throws {
        var p = ImpPreferences()
        p.shortcuts = []
        p.click = .talk
        p.doubleClickOpensSettings = false
        // As saved by a version before click triggers: no `clicksSetUp`.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json["clicksSetUp"] = nil
        var old = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.shortcuts.isEmpty)
        old.upgrade()
        let imp = old.imps[0].id
        #expect(old.clickShortcut(1, on: imp, in: nil)?.command == .talk)
        #expect(old.clickShortcut(2, on: imp, in: nil) == nil)
        let before = old
        old.upgrade()
        #expect(old == before, "only once")
    }

    @Test func mouseGamesSwitchedOffStayOffAnimationByAnimation() throws {
        var p = ImpPreferences()
        p.mouseGames = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        json["clicksSetUp"] = nil
        var old = try JSONDecoder().decode(ImpPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        old.upgrade()
        #expect(old.mouseGames, "the hidden switch is back on…")
        #expect(!old.isEnabled(.dizzy) && !old.isEnabled(.pet), "…and the cursor games are off one by one")
        #expect(old.isEnabled(.angry) && old.isEnabled(.cuddle), "clicks and handling never were mouse games")
    }

    @Test func anImpsOwnClickWinsOverTheShared() {
        var p = ImpPreferences()
        let imp = p.imps[0].id
        p.shortcuts.append(Shortcut(name: "Chat", prompt: "", performer: imp, usesClipboard: false, trigger: .clicks(1), command: .chat))
        #expect(p.clickShortcut(1, on: imp, in: nil)?.command == .chat)
        #expect(p.clickShortcut(1, on: UUID(), in: nil)?.command == .type, "others still type")
    }

    @Test func clickConditionsNeedState() {
        var p = ImpPreferences()
        let imp = p.imps[0].id
        p.shortcuts = [Shortcut(name: "Night", prompt: "Good night", performer: imp, usesClipboard: false,
                                trigger: .clicks(1), conditions: [Trigger(.hours, number: 22 * 60, until: 6 * 60)])]
        #expect(p.clickShortcut(1, on: imp, in: nil) == nil)
        #expect(p.clickShortcut(1, on: imp, in: MacState(minuteOfDay: 23 * 60)) != nil)
        #expect(p.clickShortcut(1, on: imp, in: MacState(minuteOfDay: 12 * 60)) == nil)
    }
}

@Suite struct OwnToolTests {
    let imp = UUID()

    @Test func theTranslateShortcutFromTheExample() throws {
        let args = try JSONValue(jsonString: #"""
        {"name":"Translate picture","when":{"kind":"keys","keys":"ctrl+cmd+T"},"with_clipboard":true,
         "prompt":"Translate the text in the image into Chinese and show the new image."}
        """#)
        let s = try Shortcut(tool: args, imp: imp)
        #expect(s.trigger.kind == .keys && s.usesClipboard && s.performer == imp && s.command == .ask)
        #expect(s.hotkey == Hotkey(keyCode: 17, modifiers: Hotkey.control | Hotkey.command))
        #expect(s.hotkey?.displayString == "⌃⌘T")
    }

    @Test func eventsWithConditions() throws {
        let args = try JSONValue(jsonString: #"""
        {"when":{"kind":"battery","number":20},"only_if":[{"kind":"hours","text":"9:00-18:00"},{"kind":"charger","flag":false}],
         "prompt":"Suggest how to save power.","every_imp":true}
        """#)
        let s = try Shortcut(tool: args, imp: imp)
        #expect(s.trigger == Trigger(.battery, number: 20) && s.performer == nil && !s.usesClipboard)
        #expect(s.conditions == [Trigger(.hours, number: 540, until: 1080), Trigger(.charger, flag: false)])
        #expect(s.name == "Battery below 20 %")
    }

    @Test func changingKeepsTheIDAndTheSwitch() throws {
        var old = Shortcut(name: "Old", prompt: "x", performer: imp, trigger: .clicks(3))
        old.isEnabled = false
        let s = try Shortcut(tool: JSONValue(jsonString: #"{"when":{"kind":"clicks","number":2},"do":"chat"}"#), imp: imp, replacing: old)
        #expect(s.id == old.id && !s.isEnabled && s.name == "Old" && s.command == .chat && s.trigger == .clicks(2))
    }

    @Test func mistakesComeBackInWords() throws {
        func error(_ json: String) -> String? {
            do { _ = try Shortcut(tool: JSONValue(jsonString: json), imp: imp); return nil }
            catch { return error.localizedDescription }
        }
        #expect(error(#"{"prompt":"x"}"#)?.contains("when") == true)
        #expect(error(#"{"when":{"kind":"sometimes"},"prompt":"x"}"#)?.contains("Unknown") == true)
        #expect(error(#"{"when":{"kind":"keys","keys":"T"},"prompt":"x"}"#)?.contains("⌘") == true, "a bare letter would steal typing")
        #expect(error(#"{"when":{"kind":"clicks","number":7},"prompt":"x"}"#) != nil)
        #expect(error(#"{"when":{"kind":"wake"},"only_if":[{"kind":"wake"}],"prompt":"x"}"#)?.contains("condition") == true)
        #expect(error(#"{"when":{"kind":"wake"}}"#)?.contains("prompt") == true, "asking needs something to ask")
    }

    @Test func hotkeysFromWords() {
        #expect(Hotkey(parsing: "⌃⌘T") == Hotkey(keyCode: 17, modifiers: Hotkey.control | Hotkey.command))
        #expect(Hotkey(parsing: "Control-Option-Space") == Hotkey(keyCode: 49, modifiers: Hotkey.control | Hotkey.option))
        #expect(Hotkey(parsing: "f18") == Hotkey(keyCode: 79))
        #expect(Hotkey(parsing: "hyper+T") == nil && Hotkey(parsing: "") == nil)
    }

    @Test func theImageServerFromTheExample() throws {
        let args = try JSONValue(jsonString: #"""
        {"command":"npx -y @dtst/img","env":{"OPENAI_BASE_URL":"https://openrouter.ai/api/v1","OPENAI_API_KEY":"sk-...","OPENAI_MODEL":"meta/muse-image"}}
        """#)
        let server = try MCPServerConfig(tool: args)
        #expect(server.transport == .stdio && server.command == "npx" && server.arguments == ["-y", "@dtst/img"])
        #expect(server.name == "Img")
        #expect(server.missingSecrets == ["OPENAI_API_KEY"])
        #expect(throws: ToolArgumentError.self) { try MCPServerConfig(tool: JSONValue(jsonString: #"{"url":"ftp://x"}"#)) }
    }

    @Test func groupsDecideTheTools() {
        let all = OwnTools.specs(Set(ImpToolGroup.allCases), animations: ["yes"], imps: ["Pip"], browser: true).map(\.name)
        #expect(all.contains(OwnTools.play) && all.contains(OwnTools.page) && all.contains(OwnTools.message))
        for name in all { #expect(OwnTools.group(of: name) != nil, "\(name) has a group") }
        let quiet = OwnTools.specs([.senses], animations: [], imps: [], browser: false).map(\.name)
        #expect(quiet == [OwnTools.status])
        #expect(OwnTools.specs([.troupe], animations: [], imps: [], browser: false).isEmpty, "nobody to talk to")
        #expect(all.allSatisfy { ToolSet.functionName($0) == $0 }, "valid function names")
    }

    @Test func profilesSwitchGroupsOff() throws {
        var p = ImpProfile.imp
        #expect(p.ownTools == Set(ImpToolGroup.allCases.filter(\.isOnByDefault)) && !p.uses(.computer))
        p.setUses(.setup, false)
        #expect(!p.uses(.setup) && p.uses(.body))
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        p.setUses(.setup, true)
        #expect(p == ImpProfile.imp)
    }
}

@Suite struct TravelTests {
    @Test func everyJourneyStartsAndEndsOnTheSpot() {
        let a = CGPoint(x: 100, y: 50), b = CGPoint(x: 900, y: 600)
        for travel in Travel.allCases {
            let path = TravelPath(from: a, to: b, travel, size: 112)
            #expect(path.at(0).origin == a, "\(travel) starts at the start")
            let end = path.at(1).origin
            #expect(abs(end.x - b.x) < 0.001 && abs(end.y - b.y) < 0.001, "\(travel) ends at the end")
            #expect(path.duration > 0.3 && path.duration < 2.5)
        }
    }

    @Test func hopsLeaveTheGroundAndSlidesDont() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 600, y: 0)
        #expect(TravelPath(from: a, to: b, .hop, size: 112).at(0.5).origin.y > 80)
        #expect(TravelPath(from: a, to: b, .jump, size: 112).at(0.5).origin.y > TravelPath(from: a, to: b, .hop, size: 112).at(0.5).origin.y)
        #expect(TravelPath(from: a, to: b, .slide, size: 112).at(0.5).origin.y == 0)
        #expect(TravelPath(from: a, to: b, .slide, size: 112).at(0.25).lean > 0, "leans into a slide to the right")
        let bounce = TravelPath(from: a, to: b, .bounce, size: 112)
        let landings = [0.45, 0.78].map { bounce.at($0).origin.y }
        #expect(landings.allSatisfy { $0 < 1 }, "touches down between bounces")
        #expect(bounce.at(0.225).origin.y > bounce.at(0.615).origin.y, "each bounce lower")
    }

    @Test func anImpFromThePhoneGlidesInAtItsHeight() {
        let a = CGPoint(x: -116, y: 400), b = CGPoint(x: 380, y: 400)
        let glide = GlidePath(from: a, to: b, speed: 1_800)
        #expect(glide.at(0).origin == a)
        #expect(abs(glide.at(1).origin.x - b.x) < 0.001 && abs(glide.at(1).origin.y - b.y) < 0.001)
        #expect(abs(glide.at(1).lean) < 0.001, "lands upright")
        #expect(glide.duration >= 0.65 && glide.duration <= 1.5)
        // No hop: it stays near the height it was thrown at all the way.
        let ys = stride(from: 0.0, through: 1, by: 0.05).map { glide.at($0).origin.y }
        #expect(ys.allSatisfy { abs($0 - 400) <= 14 })
        // Fast at first, braking to a stop.
        let early = glide.at(0.1).origin.x - glide.at(0).origin.x
        let late = glide.at(1).origin.x - glide.at(0.9).origin.x
        #expect(early > late * 5)
        #expect(glide.at(0.2).lean > 0, "leans into a glide to the right")
        #expect(GlidePath(from: b, to: a, speed: 1_800).at(0.2).lean < 0)
        // A harder throw arrives quicker; a gentle push (speed 0) still gets there.
        #expect(GlidePath(from: a, to: b, speed: 2_500).duration < GlidePath(from: a, to: b, speed: 1_000).duration)
        #expect(GlidePath(from: a, to: b, speed: 0).duration <= 1.5)
    }

    @Test func aBurstCountsItsClicks() {
        var b = ClickBurst(interval: 0.3)
        _ = b.click(at: 1); _ = b.click(at: 1.1); _ = b.click(at: 1.2)
        #expect(b.finish(at: 1.3) == nil, "may still go on")
        #expect(b.finish(at: 1.5) == 3)
        #expect(b.finish(at: 2) == nil, "counted once")
        for t in [3.0, 3.1, 3.2, 3.3] { _ = b.click(at: t) }
        #expect(b.finish(at: 3.7) == nil, "a flurry already played")
    }
}
