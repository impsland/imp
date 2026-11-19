import Foundation
import Testing
@testable import ImpKit

/// The scope rules (`SettingScope`): a change made for one Imp stays with that Imp, the shared items
/// change only when Every Imp is picked, and a new Imp starts from the shared items.
@Suite struct SettingScopeTests {
    /// Two Imps (Pip and Bob) and one shared trigger every Imp answers to.
    private func troupe() -> (prefs: ImpPreferences, pip: UUID, bob: UUID, shared: Shortcut) {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        for i in prefs.imps.indices { prefs.imps[i].isActive = true }
        let shared = Shortcut(name: "Translate", hotkey: Hotkey(parsing: "ctrl+cmd+T"), steps: [Step(.ask, value: "Translate it.")])
        prefs.shortcuts = [shared]
        return (prefs, pip, bob, shared)
    }

    // MARK: Triggers

    @Test func anEditForOneImpLeavesTheOthersAndTheSharedOneAlone() throws {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.steps = [Step(.ask, value: "Translate it into French.")]
        let id = prefs.saveTrigger(edited, for: .imp(pip))
        #expect(id != shared.id)
        #expect(prefs.sharedShortcuts == [shared], "the shared one is untouched")
        #expect(prefs.triggers(for: bob) == [shared], "Bob keeps the shared one")
        let mine = try #require(prefs.triggers(for: pip).first)
        #expect(prefs.triggers(for: pip).count == 1 && mine.steps.first?.text == "Translate it into French.")
        #expect(mine.performer == pip && mine.overrides == shared.id)
        #expect(prefs.scope(of: mine, for: pip) == .changed)
        #expect(prefs.scope(of: shared, for: bob) == .everyImp)
        // Editing it again changes Pip's version in place.
        edited.steps = [Step(.ask, value: "Into German.")]
        #expect(prefs.saveTrigger(edited, for: .imp(pip)) == id)
        #expect(prefs.shortcuts.count == 2)
    }

    @Test func justForOneImpNoLongerTakesItFromTheOthers() {
        var (prefs, pip, bob, shared) = troupe()
        prefs.saveTrigger(shared, for: .imp(pip))
        #expect(prefs.triggers(for: bob).map(\.id) == [shared.id])
        #expect(prefs.triggers(for: pip).allSatisfy { $0.performer == pip })
        let newcomer = prefs.addNewcomer()
        #expect(prefs.triggers(for: newcomer).map(\.id) == [shared.id], "a new Imp still gets it")
    }

    @Test func switchingASharedTriggerOffIsForThatImpAlone() {
        var (prefs, pip, bob, shared) = troupe()
        prefs.setTrigger(shared.id, enabled: false, for: pip)
        #expect(prefs.sharedShortcuts.first?.isEnabled == true)
        #expect(prefs.triggers(for: bob).first?.isEnabled == true)
        #expect(prefs.triggers(for: pip).first?.isEnabled == false)
        #expect(!prefs.runs(shared, on: pip) && prefs.runs(shared, on: bob))
    }

    @Test func removingAnImpsVersionBringsTheSharedOneBack() {
        var (prefs, pip, _, shared) = troupe()
        let id = prefs.saveTrigger(shared, for: .imp(pip))
        prefs.removeTrigger(shared.id, for: pip)
        #expect(prefs.sharedShortcuts == [shared], "a shared one is never removed from one Imp's settings")
        prefs.removeTrigger(id, for: pip)
        #expect(prefs.triggers(for: pip) == [shared])
    }

    @Test func everyImpIsAnExplicitChoice() throws {
        var (prefs, pip, bob, shared) = troupe()
        var bobs = shared
        bobs.steps = [Step(.ask, value: "Bob's way.")]
        prefs.saveTrigger(bobs, for: .imp(bob))
        var pips = shared
        pips.steps = [Step(.ask, value: "For everyone now.")]
        let id = prefs.saveTrigger(pips, for: .imp(pip))
        var promoted = try #require(prefs.shortcuts.first { $0.id == id })
        promoted.name = "Translate better"
        #expect(prefs.saveTrigger(promoted, for: .everyImp) == shared.id, "written into the shared one")
        #expect(prefs.sharedShortcuts.map { $0.steps.first?.text } == ["For everyone now."])
        #expect(prefs.shortcuts(of: pip).isEmpty, "Pip's version went into it")
        #expect(prefs.triggers(for: bob).map { $0.steps.first?.text } == ["Bob's way."], "Bob's own version stays")
        // An Imp's own trigger shared with every Imp.
        let own = Shortcut(name: "Mine", performer: pip, steps: [Step(.ask, value: "x")])
        prefs.saveTrigger(own, for: .imp(pip))
        prefs.saveTrigger(own, for: .everyImp)
        #expect(prefs.sharedShortcuts.contains { $0.id == own.id })
    }

    @Test func deletingASharedTriggerLeavesTheImpsVersions() {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.steps = [Step(.ask, value: "Mine.")]
        prefs.saveTrigger(edited, for: .imp(pip))
        prefs.removeSharedTrigger(shared.id)
        #expect(prefs.triggers(for: bob).isEmpty)
        #expect(prefs.triggers(for: pip).map { $0.steps.first?.text } == ["Mine."])
        #expect(prefs.triggers(for: pip).first.map { prefs.scope(of: $0, for: pip) } == .onlyThisImp)
    }

    @Test func anotherImpsTriggerIsCopiedNeverTaken() {
        var (prefs, pip, bob, _) = troupe()
        let bobs = Shortcut(name: "Bob's", performer: bob, steps: [Step(.ask, value: "x")])
        prefs.shortcuts.append(bobs)
        prefs.saveTrigger(bobs, for: .imp(pip))
        #expect(prefs.shortcuts(of: bob) == [bobs])
        #expect(prefs.shortcuts(of: pip).count == 1 && prefs.shortcuts(of: pip)[0].id != bobs.id)
    }

    @Test func keysRunTheVersionOfTheImpTheyGoTo() throws {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.steps = [Step(.ask, value: "Pip's way.")]
        prefs.saveTrigger(edited, for: .imp(pip))
        let keys = try #require(shared.keys)
        let toPip = try #require(prefs.keyed(keys, focus: pip))
        #expect(toPip.imp == pip && toPip.shortcut.steps.first?.text == "Pip's way.")
        let toBob = try #require(prefs.keyed(keys, focus: bob))
        #expect(toBob.imp == bob && toBob.shortcut.id == shared.id)
    }

    @Test func clicksUseTheImpsVersion() {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let click = Shortcut(name: "Type", trigger: Trigger(.click, value: "1"), steps: [Step(.open, value: "text_box")])
        prefs.shortcuts = [click]
        var chat = click
        chat.steps = [Step(.open, value: "chat")]
        prefs.saveTrigger(chat, for: .imp(pip))
        #expect(prefs.clickShortcut(1, on: pip, in: nil)?.steps.first?.target == .chat)
        #expect(prefs.clickShortcut(1, on: bob, in: nil)?.steps.first?.target == .textBox)
    }

    // MARK: New Imps

    @Test func aNewImpStartsFromTheSharedSetNotFromAnotherImp() {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer()
        let service = Service(name: "Own", baseURL: "http://localhost:1/v1", model: "m")
        prefs.ai.add(service)
        var server = MCPServerConfig(name: "Notes", transport: .stdio, command: "notes")
        server.id = UUID()
        prefs.mcpServers = [server]
        let i = prefs.imps.firstIndex { $0.id == pip }!
        prefs.imps[i].brain = Brain(service: service.id)
        prefs.imps[i].servers = [server.id]
        prefs.saveTrigger(Shortcut(name: "Pip's", hotkey: Hotkey(keyCode: 79), steps: [Step(.ask, value: "x")]), for: .imp(pip))
        prefs.save(MadeAnimation(name: "Pip's dance", beats: [AnimationBeat(duration: 1)]), for: pip)
        prefs.save(MadeAnimation(name: "Everyone's dance", beats: [AnimationBeat(duration: 1)]), for: nil)

        let newcomer = prefs.addNewcomer()
        let profile = prefs.imps.first { $0.id == newcomer }!
        #expect(profile.brain == nil, "it follows the default Brain")
        #expect(profile.servers.isEmpty && profile.animations.isEmpty && !profile.isActive)
        #expect(prefs.shortcuts(of: newcomer).isEmpty)
        #expect(prefs.triggers(for: newcomer).map(\.id) == prefs.sharedShortcuts.map(\.id))
        #expect(prefs.originals(for: newcomer).map(\.name) == ["Everyone's dance"])
        #expect(!prefs.imps.dropLast().contains { $0.name == profile.name })
    }

    // MARK: Animations

    @Test func anAnimationChangedForOneImpLeavesTheSharedOne() throws {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let shared = MadeAnimation(name: "Dance", beats: [AnimationBeat(duration: 1)])
        let sharedID = prefs.save(shared, for: nil)
        var mine = try #require(prefs.animationLibrary.first)
        mine.beats = [AnimationBeat(duration: 2)]
        let id = prefs.save(mine, for: pip)
        #expect(id != sharedID)
        #expect(prefs.animationLibrary.map(\.id) == [sharedID] && prefs.animationLibrary[0].duration == 1, "untouched")
        #expect(prefs.originals(for: bob).map(\.id) == [sharedID])
        #expect(prefs.originals(for: pip).map(\.id) == [id])
        #expect(prefs.customAnimation(sharedID, imp: pip)?.duration == 2, "a trigger playing the shared one plays Pip's version")
        #expect(prefs.scope(ofAnimation: id, for: pip) == .changed)
        #expect(prefs.customAnimation(sharedID, imp: bob)?.id == sharedID)
        // Removing the shared one leaves Pip's as its own.
        prefs.removeAnimation(sharedID)
        #expect(prefs.originals(for: pip).map(\.id) == [id] && prefs.scope(ofAnimation: id, for: pip) == .onlyThisImp)
        #expect(prefs.originals(for: bob).isEmpty)
    }

    @Test func movingAnImpsAnimationToEveryImpIsExplicit() throws {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer()
        let own = MadeAnimation(name: "Mine", beats: [AnimationBeat(duration: 1)])
        prefs.save(own, for: pip)
        prefs.save(own, for: nil)
        #expect(prefs.animationLibrary.map(\.id) == [own.id])
        #expect(prefs.ownAnimations(of: pip).isEmpty)
    }
}

/// A first launch has no triggers and no animations: everything is made or added by the user.
@Suite struct FirstLaunchTests {
    @Test func aFirstLaunchHasNoTriggersAndNoAnimations() {
        let fresh = ImpPreferences.withWaitingImp()
        #expect(fresh.shortcuts.isEmpty && fresh.animationLibrary.isEmpty)
        #expect(ImpPreferences.withWaitingImp().shortcuts.isEmpty)
        let defaults = UserDefaults(suiteName: "FirstLaunchTests-\(UUID().uuidString)")!
        #expect(PreferencesStore(defaults: defaults).load().shortcuts.isEmpty)
    }

    @Test func exportingSharedTriggersOfAFreshLaunchIsEmpty() {
        let kit = Kit.exporting(imps: [], from: ImpPreferences.withWaitingImp(), shared: true)
        #expect(kit.triggers.isEmpty)
    }

    @Test func aKitTriggerRoundTripsEveryStep() throws {
        let steps = [Step(.ask, value: "Do it", clipboard: true), Step(.say, value: "Hi", aloud: true), Step(.play, value: "Wiggle"),
                     Step(.sleep, value: "Nod"), Step(.wake), Step(.follow, value: "glide", speed: 1.5), Step(.open, value: "chat")]
        for step in steps {
            let s = Shortcut(name: step.act.rawValue, trigger: Trigger(.click, value: "3"), steps: [step, Step(.say, value: "Done")])
            let back = try Kit.parse(Kit(triggers: [s]).json())
            #expect(back.triggers.first?.steps == s.steps)
            #expect(back.triggers.first?.trigger == s.trigger)
        }
    }
}

/// An Imp changing its own version through its tools keeps it a version of the shared one.
@Suite struct TriggerToolScopeTests {
    private func args(_ id: UUID? = nil, seconds: Double, everyImp: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["on": .string("idle"), "value": .number(seconds), "do": .array([.object(["act": .string("sleep")])])]
        if let id { o["id"] = .string(id.uuidString) }
        if everyImp { o["for"] = .string("every_imp") }
        return .object(o)
    }

    @Test func anImpsToolEditKeepsItsVersionAVersion() throws {
        var prefs = ImpPreferences.withWaitingImp()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let shared = Shortcut(name: "Nap", trigger: Trigger(.idle, value: "60"), steps: [Step(.sleep)])
        prefs.shortcuts = [shared]
        // The Imp changes the shared one without every_imp: its own version.
        var edit = try Shortcut(tool: args(shared.id, seconds: 90), imp: pip, replacing: shared)
        let id = prefs.saveTrigger(edit, for: .imp(pip))
        #expect(prefs.sharedShortcuts == [shared] && prefs.triggers(for: bob) == [shared])
        // And again, now on its version.
        let version = try #require(prefs.shortcuts.first { $0.id == id })
        edit = try Shortcut(tool: args(id, seconds: 120), imp: pip, replacing: version)
        prefs.saveTrigger(edit, for: .imp(pip))
        #expect(prefs.triggers(for: pip).count == 1 && prefs.triggers(for: pip)[0].trigger.idleSeconds == 120)
        #expect(prefs.scope(of: prefs.triggers(for: pip)[0], for: pip) == .changed)
    }

    @Test func everyImpInTheArgumentsGivesASharedTrigger() throws {
        let pip = UUID()
        let mine = try Shortcut(tool: args(seconds: 30), imp: pip)
        #expect(mine.performer == pip)
        let shared = try Shortcut(tool: args(seconds: 30, everyImp: true), imp: pip)
        #expect(shared.performer == nil)
        var prefs = ImpPreferences.withWaitingImp()
        prefs.shortcuts = [shared]
        #expect(prefs.sharedShortcuts.map(\.id) == [shared.id])
    }
}

/// The 60 s rest (`Shortcut.mayRun`): only a trigger that asks the model and was set off by something other than the person.
@Suite struct TriggerRestTests {
    let now = Date()
    private func trigger(_ event: TriggerEvent, _ steps: [Step]) -> Shortcut {
        Shortcut(name: "T", hotkey: event == .keys ? Hotkey(keyCode: 79) : nil, trigger: Trigger(event), steps: steps)
    }

    @Test func onlyAskingTriggersSetOffByTheMacRest() {
        let recent = now.addingTimeInterval(-10), old = now.addingTimeInterval(-61)
        let ask = [Step(.ask, value: "x")], say = [Step(.say, value: "x")]
        for e in [TriggerEvent.start, .every, .idle, .battery, .app] {
            let t = trigger(e, ask)
            #expect(t.restsAfterGoingOff)
            #expect(!t.mayRun(lastFired: recent, isFree: true, now: now))
            #expect(t.mayRun(lastFired: old, isFree: true, now: now))
            #expect(t.mayRun(lastFired: nil, isFree: true, now: now))
            #expect(!trigger(e, say).restsAfterGoingOff && trigger(e, say).mayRun(lastFired: recent, isFree: true, now: now))
        }
        for e in [TriggerEvent.keys, .click, .poke, .stroke, .near, .away] {
            let t = trigger(e, ask)
            #expect(!t.restsAfterGoingOff && t.mayRun(lastFired: recent, isFree: false, now: now), "\(e) is the person's own doing")
        }
    }

    @Test func gesturesMapFromMacEvents() {
        for g in TriggerEvent.gestures {
            #expect(Trigger(g).matches(.gesture(g)))
            #expect(!Trigger(g).matches(.gesture(g == .poke ? .hold : .poke)))
            #expect(!Trigger(g).matches(.away))
        }
        #expect(Trigger(.click, value: "2").matches(.click(2)) && !Trigger(.click, value: "2").matches(.click(1)))
        #expect(Trigger(.near, value: "3").matches(.near(from: 2, to: 3)) && !Trigger(.near, value: "3").matches(.near(from: 3, to: 4)))
        #expect(Trigger(.away).matches(.away))
    }
}
