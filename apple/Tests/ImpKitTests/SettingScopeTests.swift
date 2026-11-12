import Foundation
import Testing
@testable import ImpKit

/// The scope rules (`SettingScope`): a change made for one Imp stays with that Imp, the shared items
/// change only when Every Imp is picked, and a new Imp starts from the shared items.
@Suite struct SettingScopeTests {
    /// Two Imps (Pip and Bob) and one shared trigger every Imp answers to.
    private func troupe() -> (prefs: ImpPreferences, pip: UUID, bob: UUID, shared: Shortcut) {
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        for i in prefs.imps.indices { prefs.imps[i].isActive = true }
        let shared = Shortcut(name: "Translate", hotkey: Hotkey(parsing: "ctrl+cmd+T"), prompt: "Translate it.")
        prefs.shortcuts = [shared]
        return (prefs, pip, bob, shared)
    }

    // MARK: Triggers

    @Test func anEditForOneImpLeavesTheOthersAndTheSharedOneAlone() throws {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.prompt = "Translate it into French."
        let id = prefs.saveTrigger(edited, for: .imp(pip))
        #expect(id != shared.id)
        #expect(prefs.sharedShortcuts == [shared], "the shared one is untouched")
        #expect(prefs.triggers(for: bob) == [shared], "Bob keeps the shared one")
        let mine = try #require(prefs.triggers(for: pip).first)
        #expect(prefs.triggers(for: pip).count == 1 && mine.prompt == "Translate it into French.")
        #expect(mine.performer == pip && mine.overrides == shared.id)
        #expect(prefs.scope(of: mine, for: pip) == .changed)
        #expect(prefs.scope(of: shared, for: bob) == .everyImp)
        // Editing it again changes Pip's version in place.
        edited.prompt = "Into German."
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
        bobs.prompt = "Bob's way."
        prefs.saveTrigger(bobs, for: .imp(bob))
        var pips = shared
        pips.prompt = "For everyone now."
        let id = prefs.saveTrigger(pips, for: .imp(pip))
        var promoted = try #require(prefs.shortcuts.first { $0.id == id })
        promoted.name = "Translate better"
        #expect(prefs.saveTrigger(promoted, for: .everyImp) == shared.id, "written into the shared one")
        #expect(prefs.sharedShortcuts.map(\.prompt) == ["For everyone now."])
        #expect(prefs.shortcuts(of: pip).isEmpty, "Pip's version went into it")
        #expect(prefs.triggers(for: bob).map(\.prompt) == ["Bob's way."], "Bob's own version stays")
        // An Imp's own trigger shared with every Imp.
        let own = Shortcut(name: "Mine", prompt: "x", performer: pip)
        prefs.saveTrigger(own, for: .imp(pip))
        prefs.saveTrigger(own, for: .everyImp)
        #expect(prefs.sharedShortcuts.contains { $0.id == own.id })
    }

    @Test func deletingASharedTriggerLeavesTheImpsVersions() {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.prompt = "Mine."
        prefs.saveTrigger(edited, for: .imp(pip))
        prefs.removeSharedTrigger(shared.id)
        #expect(prefs.triggers(for: bob).isEmpty)
        #expect(prefs.triggers(for: pip).map(\.prompt) == ["Mine."])
        #expect(prefs.triggers(for: pip).first.map { prefs.scope(of: $0, for: pip) } == .onlyThisImp)
    }

    @Test func anotherImpsTriggerIsCopiedNeverTaken() {
        var (prefs, pip, bob, _) = troupe()
        let bobs = Shortcut(name: "Bob's", prompt: "x", performer: bob)
        prefs.shortcuts.append(bobs)
        prefs.saveTrigger(bobs, for: .imp(pip))
        #expect(prefs.shortcuts(of: bob) == [bobs])
        #expect(prefs.shortcuts(of: pip).count == 1 && prefs.shortcuts(of: pip)[0].id != bobs.id)
    }

    @Test func keysRunTheVersionOfTheImpTheyGoTo() throws {
        var (prefs, pip, bob, shared) = troupe()
        var edited = shared
        edited.prompt = "Pip's way."
        prefs.saveTrigger(edited, for: .imp(pip))
        let keys = try #require(shared.keys)
        let toPip = try #require(prefs.keyed(keys, focus: pip))
        #expect(toPip.imp == pip && toPip.shortcut.prompt == "Pip's way.")
        let toBob = try #require(prefs.keyed(keys, focus: bob))
        #expect(toBob.imp == bob && toBob.shortcut.id == shared.id)
    }

    @Test func clicksUseTheImpsVersion() {
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let click = Shortcut(name: "Type", prompt: "", usesClipboard: false, trigger: .clicks(1), command: .type)
        prefs.shortcuts = [click]
        var chat = click
        chat.command = .chat
        prefs.saveTrigger(chat, for: .imp(pip))
        #expect(prefs.clickShortcut(1, on: pip, in: nil)?.command == .chat)
        #expect(prefs.clickShortcut(1, on: bob, in: nil)?.command == .type)
    }

    // MARK: New Imps

    @Test func aNewImpStartsFromTheSharedSetNotFromAnotherImp() {
        var prefs = ImpPreferences.firstLaunch
        let pip = prefs.addNewcomer()
        let service = Service(name: "Own", baseURL: "http://localhost:1/v1", model: "m")
        prefs.ai.add(service)
        var server = MCPServerConfig(name: "Notes", transport: .stdio, command: "notes")
        server.id = UUID()
        prefs.mcpServers = [server]
        let i = prefs.imps.firstIndex { $0.id == pip }!
        prefs.imps[i].brain = Brain(service: service.id)
        prefs.imps[i].servers = [server.id]
        prefs.saveTrigger(Shortcut(name: "Pip's", prompt: "x"), for: .imp(pip))
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
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let shared = MadeAnimation(name: "Dance", triggers: [.poke], beats: [AnimationBeat(duration: 1)])
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
        #expect(prefs.ref(for: .poke, imp: pip) == .custom(id) && prefs.ref(for: .poke, imp: bob) == .custom(sharedID))
        // Removing the shared one leaves Pip's as its own.
        prefs.removeAnimation(sharedID)
        #expect(prefs.originals(for: pip).map(\.id) == [id] && prefs.scope(ofAnimation: id, for: pip) == .onlyThisImp)
        #expect(prefs.originals(for: bob).isEmpty)
    }

    @Test func anImpsVersionOfABuiltInOneSwitchesForThatImpAlone() {
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let version = MadeAnimation(name: "", replaces: .smile, beats: [AnimationBeat(duration: 1)])
        let id = prefs.save(version, for: pip)
        prefs.setEnabled(false, animation: id)
        #expect(prefs.isEnabled(.smile), "the built-in one stays on for every Imp")
        #expect(!prefs.isEnabled(.preset(.smile), imp: pip) && prefs.isEnabled(.preset(.smile), imp: bob))
        #expect(!prefs.refs(for: .idle, imp: pip).contains(.preset(.smile)))
        #expect(prefs.refs(for: .idle, imp: bob).contains(.preset(.smile)))
        // Its starts are the built-in one's, and can't be changed from the Imp's version.
        let before = prefs.rule(for: .smile)
        prefs.setTrigger(.poke, true, animation: id)
        #expect(prefs.rule(for: .smile) == before)
        #expect(prefs.rule(ofMade: prefs.imps.first { $0.id == pip }!.animations[0], owner: pip).triggers == before.triggers)
    }

    @Test func movingAnImpsAnimationToEveryImpIsExplicit() throws {
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer()
        let own = MadeAnimation(name: "Mine", beats: [AnimationBeat(duration: 1)])
        prefs.save(own, for: pip)
        prefs.save(own, for: nil)
        #expect(prefs.animationLibrary.map(\.id) == [own.id])
        #expect(prefs.ownAnimations(of: pip).isEmpty)
    }
}

/// The starter kit is data, read and added like any kit.
@Suite struct StarterKitTests {
    @Test func itIsAKitWithTheStarterTriggers() throws {
        let kit = try Kit.starter()
        #expect(kit.problems.isEmpty)
        #expect(kit.triggers.map(\.name) == ["Type", "Settings", "Fall asleep", "Wake up"])
        #expect(kit.triggers.map(\.command) == [.type, .settings, .sleep, .wakeUp])
        #expect(kit.triggers.allSatisfy { $0.performer == nil && !$0.usesClipboard })
    }

    @Test func bareSettingsHaveNothingAndAFirstLaunchHasTheStarterKitForEveryImp() throws {
        #expect(ImpPreferences().shortcuts.isEmpty && ImpPreferences().animationLibrary.isEmpty)
        let fresh = ImpPreferences.firstLaunch
        #expect(fresh.shortcuts.map(\.name) == (try Kit.starter()).triggers.map(\.name))
        #expect(fresh.shortcuts.allSatisfy { $0.performer == nil })
    }

    @Test func aRemovedStarterTriggerIsNotPutBack() throws {
        var prefs = ImpPreferences.firstLaunch
        prefs.removeSharedTrigger(prefs.shortcuts[0].id)
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(ImpPreferences.self, from: data)
        #expect(back.shortcuts.map(\.name) == ["Settings", "Fall asleep", "Wake up"])
    }

    @Test func exportingLeavesTheStarterTriggersOutUnlessChanged() {
        var prefs = ImpPreferences.firstLaunch
        prefs.shortcuts[0].prompt = "Changed"
        let kit = Kit.exporting(imps: [], from: prefs, shared: true)
        #expect(kit.triggers.map(\.name) == ["Type"])
    }

    @Test func aKitTriggerRoundTripsEveryCommand() throws {
        for command in Shortcut.Command.allCases {
            let s = Shortcut(name: command.rawValue, prompt: command == .ask ? "Do it" : "", usesClipboard: false,
                             trigger: .clicks(3), command: command)
            let back = try Kit.parse(Kit(triggers: [s]).json())
            #expect(back.triggers.first?.command == command)
        }
    }
}

/// An Imp changing its own version through its tools keeps it a version of the shared one.
@Suite struct TriggerToolScopeTests {
    @Test func anImpsToolEditKeepsItsVersionAVersion() throws {
        var prefs = ImpPreferences()
        let pip = prefs.addNewcomer(), bob = prefs.addNewcomer()
        let shared = Shortcut(name: "Nap", prompt: "", usesClipboard: false, trigger: Trigger(.idle, number: 60), command: .sleep)
        prefs.shortcuts = [shared]
        // The Imp changes the shared one without every_imp: its own version.
        var edit = try Shortcut(tool: .object(["id": .string(shared.id.uuidString), "when": .object(["kind": .string("idle"), "number": .number(90)]),
                                               "do": .string("sleep")]), imp: pip, replacing: shared)
        let id = prefs.saveTrigger(edit, for: .imp(pip))
        #expect(prefs.sharedShortcuts == [shared] && prefs.triggers(for: bob) == [shared])
        // And again, now on its version.
        let version = try #require(prefs.shortcuts.first { $0.id == id })
        edit = try Shortcut(tool: .object(["id": .string(id.uuidString), "when": .object(["kind": .string("idle"), "number": .number(120)]),
                                           "do": .string("sleep")]), imp: pip, replacing: version)
        prefs.saveTrigger(edit, for: .imp(pip))
        #expect(prefs.triggers(for: pip).count == 1 && prefs.triggers(for: pip)[0].trigger.number == 120)
        #expect(prefs.scope(of: prefs.triggers(for: pip)[0], for: pip) == .changed)
    }
}
