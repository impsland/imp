import Foundation
import Testing
@testable import ImpKit

@Suite struct TriggerTests {
    @Test func batteryGoesOffOnceWhenItCrossesTheLine() {
        let t = Trigger(.battery, value: "20")
        #expect(t.matches(.battery(from: 21, to: 19)))
        #expect(t.matches(.battery(from: 20, to: 19)))
        #expect(!t.matches(.battery(from: 19, to: 18)), "already below: no new alarm")
        #expect(!t.matches(.battery(from: 18, to: 25)), "charging up never counts")
    }

    @Test func appsMatchByNameOrBundleID() {
        #expect(Trigger(.app, value: "safari").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
        #expect(Trigger(.app, value: "com.apple.Safari").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
        #expect(Trigger(.app, value: "").matches(.app(name: "Notes", bundleID: "com.apple.Notes")), "empty: any app")
        #expect(!Trigger(.app, value: "Chrome").matches(.app(name: "Safari", bundleID: "com.apple.Safari")))
    }

    @Test func websitesMatchPartOfTheAddress() {
        let amazon = Trigger(.website, value: "amazon.com")
        #expect(amazon.matches(.page(url: "https://www.amazon.com/dp/B0", title: "")))
        #expect(Trigger(.website, value: "https://amazon.com").matches(.page(url: "https://www.amazon.com/", title: "")))
        #expect(!amazon.matches(.page(url: "https://example.com/?q=amazon", title: "")))
        #expect(!amazon.matches(.app(name: "Amazon", bundleID: "")))
    }

    @Test func clockTriggers() {
        #expect(Trigger(.at, value: "09:05").matches(.minute(ofDay: 545, absolute: 1)))
        #expect(Trigger(.every, value: "30").matches(.minute(ofDay: 0, absolute: 90)))
        #expect(!Trigger(.every, value: "30").matches(.minute(ofDay: 0, absolute: 91)))
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
        #expect(Condition(.battery, value: "20").holds(in: state))
        #expect(Condition(.charger, value: "unplugged").holds(in: state))
        #expect(Condition(.app, value: "Safari").holds(in: state))
        #expect(Condition(.website, value: "amazon").holds(in: state))
        #expect(!Condition(.busy, value: "80").holds(in: state))
        let night = Condition(.hours, value: "22:00-07:00")
        #expect(night.holds(in: state), "a window across midnight")
        state.minuteOfDay = 12 * 60
        #expect(!night.holds(in: state))
        #expect(!Condition(.battery, value: "20").holds(in: MacState()), "no battery: doesn't hold")
        #expect(Condition(.asleep, value: "true").holds(in: MacState(asleep: true)))
        #expect(!Condition(.asleep, value: "true").holds(in: MacState(asleep: false)))
        #expect(Condition(.asleep, value: "false").holds(in: MacState(asleep: false)))
    }

    @Test func aShortcutFiresOnlyWhenEveryConditionHolds() {
        let s = Shortcut(name: "Stop shopping", trigger: Trigger(.website, value: "amazon"), conditions: [Condition(.battery, value: "30")],
                         steps: [Step(.ask, value: "Stop me")])
        let visit = MacEvent.page(url: "https://amazon.com", title: "Amazon")
        #expect(s.fires(on: visit, in: MacState(battery: 10)))
        #expect(!s.fires(on: visit, in: MacState(battery: 80)))
        var off = s
        off.isEnabled = false
        #expect(!off.fires(on: visit, in: MacState(battery: 10)))
        let keys = Shortcut(name: "K", trigger: .keys, steps: [Step(.ask, value: "x")])
        #expect(!keys.fires(on: .wake, in: MacState()), "keys and clicks aren't Mac events")
    }

    @Test func clicksMatchTheirCountOnly() {
        #expect(Trigger.click(2).matches(.click(2)) && !Trigger.click(2).matches(.click(1)))
        #expect(Trigger(.click).matches(.click(1)), "no value: one click")
    }
}

@Suite struct ClickTriggerTests {
    private func open(_ target: String, name: String = "Type", performer: UUID? = nil, clicks: Int = 1) -> Shortcut {
        Shortcut(name: name, performer: performer, trigger: .click(clicks), steps: [Step(.open, value: target)])
    }

    @Test func freshSettingsAnswerToNoClicks() {
        let p = ImpPreferences.withWaitingImp()
        let imp = p.imps[0].id
        #expect(p.clickShortcut(1, on: imp, in: nil) == nil)
        #expect(p.clickShortcut(2, on: imp, in: nil) == nil)
        #expect(p.mostClicks(on: imp) == 0)
    }

    @Test func aDisabledClickTriggerIsNotAnswered() {
        var p = ImpPreferences.withWaitingImp()
        let imp = p.imps[0].id
        var s = open("text_box")
        s.isEnabled = false
        p.shortcuts = [s]
        #expect(p.clickShortcut(1, on: imp, in: nil) == nil)
        #expect(p.mostClicks(on: imp) == 0)
    }

    @Test func anImpsOwnClickComesFirstAndTheSharedOnesStillApply() {
        var p = ImpPreferences.withWaitingImp()
        let imp = p.imps[0].id
        p.shortcuts = [open("text_box"), open("chat", name: "Chat", performer: imp)]
        #expect(p.clickShortcut(1, on: imp, in: nil)?.steps.first?.target == .chat)
        #expect(p.clickShortcut(1, on: UUID(), in: nil)?.steps.first?.target == .textBox, "others still type")
        #expect(p.triggers(for: imp).map(\.name) == ["Chat", "Type"], "both run, its own first")
    }

    @Test func clickConditionsNeedState() {
        var p = ImpPreferences.withWaitingImp()
        let imp = p.imps[0].id
        p.shortcuts = [Shortcut(name: "Night", performer: imp, trigger: .click(1), conditions: [Condition(.hours, value: "22:00-06:00")],
                                steps: [Step(.say, value: "Good night")])]
        #expect(p.clickShortcut(1, on: imp, in: nil) == nil)
        #expect(p.clickShortcut(1, on: imp, in: MacState(minuteOfDay: 23 * 60)) != nil)
        #expect(p.clickShortcut(1, on: imp, in: MacState(minuteOfDay: 12 * 60)) == nil)
    }
}

@Suite struct OwnToolTests {
    let imp = UUID()

    @Test func theTranslateShortcutFromTheExample() throws {
        let args = try JSONValue(jsonString: #"""
        {"name":"Translate picture","on":"keys","value":"ctrl+cmd+T",
         "do":[{"act":"ask","value":"Translate the text in the image into Chinese and show the new image.","clipboard":true}]}
        """#)
        let s = try Shortcut(tool: args, imp: imp)
        #expect(s.trigger.event == .keys && s.steps.first?.handsOverClipboard == true && s.performer == imp && s.askStep != nil)
        #expect(s.hotkey == Hotkey(keyCode: 17, modifiers: Hotkey.control | Hotkey.command))
        #expect(s.hotkey?.displayString == "⌃⌘T")
    }

    @Test func eventsWithConditionsAndSeveralSteps() throws {
        let args = try JSONValue(jsonString: #"""
        {"on":"battery","value":20,"if":[{"state":"hours","value":"9:00-18:00"},{"state":"charger","value":"unplugged"}],
         "do":[{"act":"say","value":"Low!","aloud":true},{"act":"ask","value":"Suggest how to save power."}],"for":"every_imp"}
        """#)
        let s = try Shortcut(tool: args, imp: imp)
        #expect(s.trigger == Trigger(.battery, value: "20") && s.performer == nil && s.askStep?.handsOverClipboard == false)
        #expect(s.conditions == [Condition(.hours, value: "09:00-18:00"), Condition(.charger, value: "unplugged")])
        #expect(s.steps.map(\.act) == [.say, .ask] && s.steps[0].speaksAloud, "in the order given")
        #expect(s.name == "Battery below 20 %")
    }

    @Test func changingKeepsTheIDAndTheSwitch() throws {
        var old = Shortcut(name: "Old", performer: imp, trigger: .click(3), steps: [Step(.say, value: "x")])
        old.isEnabled = false
        let s = try Shortcut(tool: JSONValue(jsonString: #"{"on":"click","value":2,"do":[{"act":"open","value":"chat"}]}"#), imp: imp, replacing: old)
        #expect(s.id == old.id && !s.isEnabled && s.name == "Old" && s.steps.first?.target == .chat && s.trigger == .click(2))
    }

    @Test func mistakesComeBackInWords() throws {
        func error(_ json: String) -> String? {
            do { _ = try Shortcut(tool: JSONValue(jsonString: json), imp: imp); return nil }
            catch { return error.localizedDescription }
        }
        #expect(error(#"{"do":[{"act":"say","value":"x"}]}"#) != nil, "no event")
        #expect(error(#"{"on":"sometimes","do":[{"act":"say","value":"x"}]}"#) != nil)
        #expect(error(#"{"on":"keys","value":"T","do":[{"act":"say","value":"x"}]}"#)?.contains("⌘") == true, "a bare letter would steal typing")
        #expect(error(#"{"on":"click","value":7,"do":[{"act":"say","value":"x"}]}"#) != nil)
        #expect(error(#"{"on":"wake"}"#)?.contains("do") == true, "needs steps")
        #expect(error(#"{"on":"wake","do":[{"act":"say"}]}"#) != nil, "a say needs its text")
        let six = String(repeating: #"{"act":"sleep"},"#, count: 6).dropLast()
        #expect(error(#"{"on":"wake","do":["# + six + "]}") != nil, "five steps at most")
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
        let nobody = OwnTools.specs([.personality], animations: [], imps: [], browser: false).map(\.name)
        #expect(!nobody.contains(OwnTools.message) && !nobody.contains(OwnTools.openFile), "nobody to talk to")
        #expect(all.allSatisfy { ToolSet.functionName($0) == $0 }, "valid function names")
    }

    @Test func profilesSwitchGroupsOff() throws {
        var p = ImpProfile.imp
        #expect(p.ownTools == Set(ImpToolGroup.allCases.filter(\.isOnByDefault)) && !p.uses(.computer))
        p.setUses(.triggers, false)
        #expect(!p.uses(.triggers) && p.uses(.personality))
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        p.setUses(.triggers, true)
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
        // A harder throw arrives quicker. A gentle push (speed 0) still gets there.
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
