import Foundation
import Testing
@testable import ImpKit

/// What an Imp says about itself to the others, and how it waits for them.
@Suite struct TalkingDescriptionTests {
    @Test func olderDevicesSendNoDescription() throws {
        // What an older device sends: the same message without the two new keys.
        let old = try JSONEncoder().encode(LinkImp(ImpProfile.imp))
        let imp = try JSONDecoder().decode(LinkImp.self, from: old)
        #expect(imp.about == nil && imp.abilities.isEmpty)
        let json = String(decoding: old, as: UTF8.self)
        #expect(!json.contains("about") && !json.contains("abilities"))
        // And a message with them decodes.
        let new = json.dropLast() + #","about":"Maps","abilities":["shell"]}"#
        let decoded = try JSONDecoder().decode(LinkImp.self, from: Data(new.utf8))
        #expect(decoded.about == "Maps" && decoded.abilities == ["shell"])
    }

    @Test func aDescriptionRoundTrips() throws {
        var profile = ImpProfile.imp
        profile.about = "  Finds things on the web.  "
        let imp = LinkImp(profile, abilities: ["shell", "browser", "files"])
        #expect(imp.about == "Finds things on the web.")
        let back = try JSONDecoder().decode(LinkImp.self, from: JSONEncoder().encode(imp))
        #expect(back == imp)
        #expect(back.abilities == ["shell", "browser", "files"])
    }

    @Test func abilitiesFollowTheProfile() {
        var profile = ImpProfile.imp
        #expect(ImpAbilities.tags(of: profile, serverNames: ["files"]) == ["shell", "browser", "files"])
        profile.usesShell = false
        profile.setUses(.senses, false)
        #expect(ImpAbilities.tags(of: profile, serverNames: []).isEmpty)
        profile.setUses(.senses, true)
        profile.setUses(tool: ToolRegistry.ownID(.senses, tool: OwnTools.page), false)
        #expect(!ImpAbilities.tags(of: profile, serverNames: []).contains("browser"))
    }

    @Test func untrustedWordsAreCut() {
        let long = String(repeating: "x", count: 500)
        let target = ImpAbilities.profile(name: "Bo", about: long, abilities: [long, "shell"])
        #expect((target.about ?? "").count <= ImpProfile.maxAboutLength)
    }

    @Test func oldSettingsWaitByTheImpsChoice() throws {
        #expect(ImpPreferences.withWaitingImp().talkWaiting == .decides)
        var prefs = ImpPreferences.withWaitingImp()
        prefs.talkWaiting = .dontWait
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.talkWaiting == .dontWait)
        #expect(TalkWaiting.wait.waits(asked: false))
        #expect(!TalkWaiting.dontWait.waits(asked: true))
        #expect(TalkWaiting.decides.waits(asked: nil) == TalkWaiting.decides.waits(asked: nil))
    }

    @Test func anAnswerIsNotAnExchange() {
        let me = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0)
        let bo = ChatTurn.Sender(id: UUID(), name: "Bo", hue: 0.5)
        let chat = Chat(turns: [ChatTurn(request: "42", reply: "thanks", via: .answer, sender: bo),
                                ChatTurn(request: "q", reply: "a", via: .imp, sender: bo)])
        #expect(TalkLog.lines(answeredBy: me, in: [chat]).map(\.question) == ["q"])
    }
}

/// Imps are never called "Imp": that is the app.
@Suite("Imp names")
struct ImpNameTests {
    @Test func theFirstImpIsPip() {
        #expect(ImpProfile.imp.name == "Pip")
        #expect(Persona.imp.hasPrefix("You are Pip,"))
    }

    @Test func noNameInThePoolIsImpAndAFullTroupeGetsNumberedPoolNames() {
        #expect(!ImpProfile.names.contains { $0.lowercased().hasPrefix("imp") })
        #expect(Set(ImpProfile.names.map { $0.lowercased() }).count == ImpProfile.names.count)
        let full = ImpProfile.names
        #expect(ImpProfile.randomName(avoiding: full) == "Pip 2")
        #expect(ImpProfile.randomName(avoiding: full + ["Pip 2"]) == "Dot 2")
        #expect(ImpProfile.randomName(avoiding: ["Pip"], random: false) == "Dot")
    }
}
