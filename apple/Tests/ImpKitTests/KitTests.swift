import Foundation
import Testing
@testable import ImpKit

@Suite struct KitTests {
    static let full = #"""
    {"name": "Morning helper", "about": "Starts the day.",
      "triggers": [
        { "name": "Summarize", "on": "keys", "value": "ctrl+cmd+S", "do": [{"act": "ask", "value": "Summarize this.", "clipboard": true}] },
        { "name": "Low battery", "on": "battery", "value": 15, "if": [{"state": "app", "value": "Safari"}, {"state": "hours", "value": "22:00-07:00"}],
          "do": [{"act": "open", "value": "chat"}] },
        { "name": "Nine", "on": "at", "value": "9:05", "do": [{"act": "ask", "value": "Plan my day."}] }
      ],
      "mcpServers": {
        "Memory": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"] },
        "GitHub": { "command": "npx", "args": ["-y", "server-github"], "env": {"GITHUB_TOKEN": "ghp_secret"} },
        "Remote": { "url": "https://mcp.example.com/mcp?key=abc", "headers": {"Authorization": "Bearer secret"} }
      } }
    """#

    @Test func registryMetadataIsIgnored() throws {
        let kit = try Kit.parse(#"""
        {"name": "Pack", "about": "Hi",
          "registry": { "author": "someone", "tags": ["a", "b"], "summary": "One line." },
          "triggers": [ { "name": "Hi", "on": "wake", "do": [{"act": "ask", "value": "Hello"}] } ] }
        """#)
        #expect(kit.name == "Pack" && kit.triggers.count == 1 && kit.problems.isEmpty)
        let withImp = try Kit.parse(#"""
        {"name": "Pet", "registry": { "author": "x", "tags": [], "summary": "y" },
          "imps": [ { "name": "Pip", "registry": { "anything": true } } ] }
        """#)
        #expect(withImp.imps.map(\.name) == ["Pip"] && withImp.problems.isEmpty)
    }

    @Test func parsesAFullKit() throws {
        let kit = try Kit.parse(Self.full)
        #expect(kit.name == "Morning helper" && kit.about == "Starts the day.")
        #expect(kit.triggers.map(\.name) == ["Summarize", "Low battery", "Nine"])
        #expect(kit.triggers[0].keys == Hotkey(parsing: "ctrl+cmd+S") && kit.triggers[0].steps == [Step(.ask, value: "Summarize this.", clipboard: true)])
        #expect(kit.triggers[1].trigger == Trigger(.battery, value: "15") && kit.triggers[1].conditions.count == 2 && kit.triggers[1].steps.first?.target == .chat)
        #expect(kit.triggers[2].trigger.minuteOfDay == 9 * 60 + 5)
        #expect(kit.servers.map(\.name) == ["GitHub", "Memory", "Remote"])
        #expect(kit.problems.isEmpty)
    }

    @Test func badItemsDoNotSinkTheKit() throws {
        let kit = try Kit.parse(#"""
        {"triggers": [
            {"name": "Good", "on": "wake", "do": [{"act": "ask", "value": "Hi"}]},
            {"name": "Bad kind", "on": "teleport", "do": [{"act": "ask", "value": "x"}]},
            {"name": "No when", "do": [{"act": "ask", "value": "x"}]}],
         "mcpServers": {"Fine": {"command": "uvx mcp-server-fetch"}, "Broken": {"args": ["x"]}, "Text": "npx foo"}}
        """#)
        #expect(kit.triggers.map(\.name) == ["Good"])
        #expect(kit.servers.map(\.name) == ["Fine"])
        #expect(kit.problems.count == 4)
        #expect(kit.problems.contains { $0.contains("Bad kind") && $0.contains("teleport") })
        #expect(kit.problems.contains { $0.hasPrefix("Tool “Broken”") })
    }

    @Test func aKitOfOnlyBadItemsIsAnError() {
        #expect(throws: KitError.self) { try Kit.parse(#"{"triggers": [{"on": "teleport"}]}"#) }
        #expect(throws: KitError.empty) { try Kit.parse(#"{"name": "Nothing", "triggers": []}"#) }
    }

    @Test func readsAPlainMCPSnippet() throws {
        let config = try Kit.parse(#"{"mcpServers": {"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}}"#)
        #expect(config.triggers.isEmpty && config.servers.map(\.name) == ["fetch"])
        #expect(try Kit.parse("npx -y @modelcontextprotocol/server-memory").servers.first?.name == "Memory")
        #expect(try Kit.parse("https://mcp.example.com/mcp").servers.first?.transport == .http)
        // A server named like a wrapper key still reads.
        #expect(try Kit.parse(#"{"mcpServers": {"mcp": {"command": "foo"}}}"#).servers.map(\.name) == ["mcp"])
    }

    @Test func readsASingleTriggerOrAList() throws {
        let one = try Kit.parse(#"{"name": "Hello", "on": "start", "do": [{"act": "ask", "value": "Say hi."}]}"#)
        #expect(one.triggers.count == 1 && one.triggers[0].performer == nil && one.servers.isEmpty)
        let list = try Kit.parse(#"[{"on": "wake", "do": [{"act": "ask", "value": "a"}]}, {"on": "hot", "do": [{"act": "ask", "value": "b"}]}, {"nope": 1}]"#)
        #expect(list.triggers.count == 2 && list.problems.count == 1)
    }

    @Test func refusesNonKits() {
                #expect(throws: KitError.notAKit) { try Kit.parse(#"{"name": "Only a name"}"#) }
        #expect(throws: KitError.notAKit) { try Kit.parse(#"{"colour": "red"}"#) }
        #expect(throws: KitError.empty) { try Kit.parse("  \n ") }
    }

    @Test func capsSizeAndCounts() throws {
        let big = #"{"name": ""# + String(repeating: "a", count: Kit.maxBytes) + #""}"#
        #expect(throws: KitError.tooLarge) { try Kit.parse(big) }
        let triggers = Array(repeating: #"{"on": "wake", "do": [{"act": "ask", "value": "x"}]}"#, count: Kit.maxTriggers + 1).joined(separator: ",")
        #expect(throws: KitError.tooMany("triggers", Kit.maxTriggers)) { try Kit.parse("[\(triggers)]") }
        let servers = (0...Kit.maxServers).map { #""s\#($0)": {"command": "x\#($0)"}"# }.joined(separator: ",")
        #expect(throws: KitError.tooMany("tools", Kit.maxServers)) { try Kit.parse(#"{"mcpServers": {\#(servers)}}"#) }
    }

    @Test func warnsAboutCodeSecretsAndKeys() throws {
        let kit = try Kit.parse(Kit.parse(Self.full).json())      // as shared: secrets blanked
        let taken = Shortcut(name: "Mine", hotkey: Hotkey(parsing: "ctrl+cmd+S"), steps: [Step(.ask, value: "x")])
        let warnings = kit.warnings(existing: [taken])
        let code = warnings.filter { $0.kind == .runsCommand }
        #expect(code.count == 2 && code.allSatisfy(\.isCaution))
        #expect(code.contains { $0.text == "“Memory” runs a command on your Mac: npx -y @modelcontextprotocol/server-memory" })
        #expect(warnings.contains { $0.kind == .needsSecrets && $0.text.contains("GITHUB_TOKEN") })
        #expect(warnings.contains { $0.kind == .needsSecrets && $0.text.contains("Authorization") })
        #expect(warnings.contains { $0.kind == .keysInUse && $0.item == kit.triggers[0].id && $0.text.contains("“Mine”") })
        #expect(kit.warnings().allSatisfy { $0.kind != .keysInUse })
    }

    @Test func warnsAboutKeysUsedTwiceInOneKit() throws {
        let kit = try Kit.parse(#"""
        [{"on": "keys", "value": "ctrl+opt+K", "do": [{"act": "ask", "value": "a"}]}, {"on": "keys", "value": "⌃⌥K", "do": [{"act": "ask", "value": "b"}]}]
        """#)
        #expect(kit.warnings().filter { $0.kind == .keysInUse }.map(\.item) == [kit.triggers[1].id])
    }

    // MARK: Export

    @Test func exportBlanksEverySecret() throws {
        let kit = try Kit.parse(Self.full)
        for text in [kit.json(), kit.json(pretty: false), kit.link ?? ""] {
            let readable = text.hasPrefix("imp://") ? try KitSource.link(text).textValue : text
            #expect(!readable.contains("ghp_secret") && !readable.contains("Bearer secret") && !readable.contains("abc"))
        }
        let back = try Kit.parse(kit.json())
        let github = try #require(back.servers.first { $0.name == "GitHub" })
        #expect(github.environment == ["GITHUB_TOKEN": ""] && github.missingSecrets == ["GITHUB_TOKEN"])
        let remote = try #require(back.servers.first { $0.name == "Remote" })
        #expect(remote.headers == ["Authorization": ""] && remote.url == "https://mcp.example.com/mcp?key=")
    }

    @Test func roundTripKeepsTriggersAndServers() throws {
        let kit = try Kit.parse(Self.full)
        for text in [kit.json(), kit.json(pretty: false)] {
            let back = try Kit.parse(text)
            #expect(back.name == kit.name && back.about == kit.about && back.problems.isEmpty)
            #expect(back.triggers.count == kit.triggers.count)
            for (a, b) in zip(kit.triggers, back.triggers) {
                #expect(a.name == b.name && a.hotkey == b.hotkey && a.steps == b.steps)
                #expect(a.trigger == b.trigger && a.conditions == b.conditions)
            }
            #expect(back.servers.count == kit.servers.count)
            for (a, b) in zip(kit.servers, back.servers) {
                #expect(a.name == b.name && a.transport == b.transport && a.commandLine == b.commandLine)
                #expect(a.environment.mapValues { _ in "" } == b.environment && a.headers.mapValues { _ in "" } == b.headers)
            }
        }
    }

    @Test func everyKindOfTriggerRoundTrips() throws {
        let events = TriggerEvent.allCases.filter { $0 != .keys }
        let say = [Step(.say, value: "p")]
        var shortcuts = events.map { e in
            var t = Trigger.starter(e)
            if e == .app { t.value = "Safari" } else if e == .website { t.value = "example.com" }
            return Shortcut(name: "\(e)", trigger: t, steps: say)
        }
        shortcuts.append(Shortcut(name: "off", trigger: Trigger(.network, value: "online"), steps: say))
        shortcuts.append(Shortcut(name: "keys", hotkey: Hotkey(parsing: "⌃⌥⇧⌘Space"), steps: say))
        let conditions: [Condition] = TriggerState.allCases.map { st in
            var c = Condition.starter(st)
            if st == .app { c.value = "Safari" } else if st == .website { c.value = "example.com" }
            return c
        }
        shortcuts.append(Shortcut(name: "dash", hotkey: Hotkey(parsing: "⌘⌥-"), conditions: conditions, steps: say))
        let back = try Kit.parse(Kit(triggers: shortcuts).json()).triggers
        #expect(back.count == shortcuts.count)
        for (a, b) in zip(shortcuts, back) { #expect(a.trigger == b.trigger && a.conditions == b.conditions && a.hotkey == b.hotkey, "\(a.name)") }
    }

    @Test func exportIsOrderedAndReadable() {
        let kit = Kit(name: "K", triggers: [Shortcut(name: "T", trigger: .click(2), steps: [Step(.ask, value: "Do it")])],
                      servers: [MCPServerConfig(name: "S", transport: .stdio, command: "npx", arguments: ["-y", "pkg"], environment: ["KEY": "secret"])])
        let text = kit.json()
        #expect(text.hasPrefix("{\n  \"name\": \"K\","))
        #expect(text.contains("\"env\": {\n        \"KEY\": \"\"\n      }"))
        #expect(!text.contains("secret"))
    }

    @Test func linkOnlyWhenShort() throws {
        let small = Kit(triggers: [Shortcut(name: "T", trigger: .click(2), steps: [Step(.ask, value: "Hi")])])
        let link = try #require(small.link)
        #expect(link.hasPrefix("imp://add?kit=") && !link.dropFirst(14).contains(where: { "+/=".contains($0) }))
        #expect(try Kit.parse(try KitSource.link(link).textValue).triggers.first?.name == "T")
        let huge = Kit(triggers: [Shortcut(name: "T", trigger: .click(2), steps: [Step(.ask, value: String(repeating: "word ", count: 600))])])
        #expect(huge.link == nil)
    }

    // MARK: Addresses

    @Test func validatesAddresses() throws {
        #expect(try KitSource.web("https://example.com/kit.json") == .remote(URL(string: "https://example.com/kit.json")!))
        #expect(try KitSource.web("http://localhost:8000/kit.json") == .remote(URL(string: "http://localhost:8000/kit.json")!))
        #expect(try KitSource.web("http://127.0.0.1/k.json") == .remote(URL(string: "http://127.0.0.1/k.json")!))
        for bad in ["http://example.com/kit.json", "ftp://example.com/k", "file:///etc/passwd", "https://user:pw@example.com/k", "https:///x", "not a url", "javascript:alert(1)"] {
            #expect(throws: KitError.self, "\(bad)") { try KitSource.web(bad) }
        }
    }

    @Test func readsImpLinks() throws {
        #expect(try KitSource.link("imp://add?url=https%3A%2F%2Fexample.com%2Fkit.json") == .remote(URL(string: "https://example.com/kit.json")!))
        #expect(throws: KitError.self) { try KitSource.link("imp://add?url=http%3A%2F%2Fexample.com%2Fkit.json") }
        let json = #"{"triggers":[{"on": "wake","do": [{"act": "ask", "value": "é?&+/"}]}]}"#
        let b64 = Kit.base64URL(Data(json.utf8))
        #expect(try KitSource.link("imp://add?kit=\(b64)") == .text(json))
        #expect(try KitSource(input: "imp://add?kit=\(b64)") == .text(json))
        #expect(throws: KitError.self) { try KitSource.link("imp://add?kit=@@@") }
        #expect(throws: KitError.self) { try KitSource.link("imp://add") }
        #expect(throws: KitError.self) { try KitSource.link("imp://run?url=https://example.com") }
    }

    @Test func tellsInputKindsApart() throws {
        #expect(try KitSource(input: "  https://example.com/k.json\n") == .remote(URL(string: "https://example.com/k.json")!))
        #expect(throws: KitError.self) { try KitSource(input: "http://example.com/k.json") }
        #expect(try KitSource(input: #"{"imps":[]}"#) == .text(#"{"imps":[]}"#))
        #expect(try KitSource(input: "npx -y foo") == .text("npx -y foo"))
    }

    // MARK: Adding

    @Test func addsChosenItemsForOneImpOrEveryImp() throws {
        let a = ImpProfile(name: "A", hue: 0.1, favoriteHue: 0.1, personality: ""), b = ImpProfile(name: "B", hue: 0.5, favoriteHue: 0.5, personality: "")
        var prefs = ImpPreferences()
        prefs.imps = [a, b]
        let kit = try Kit.parse(Kit.parse(Self.full).json())
        let base = prefs.shortcuts.count
        let chosen = Set(kit.triggers.prefix(2).map(\.id))
        let github = try #require(kit.servers.first { $0.name == "GitHub" })
        let memory = try #require(kit.servers.first { $0.name == "Memory" })
        let added = prefs.add(kit, triggers: chosen, servers: [github.id, memory.id], for: b.id)
        #expect(added.triggers == 2 && added.servers == 2 && added.needingSecrets == [github.id])
        #expect(prefs.shortcuts.count == base + 2 && prefs.shortcuts.suffix(2).allSatisfy { $0.performer == b.id })
        #expect(prefs.imps[1].servers.count == 2 && prefs.imps[0].servers.isEmpty)

        // The same kit again: servers are reused, not doubled. "Every Imp" switches them on for all.
        var again = try Kit.parse(Kit.parse(Self.full).json())
        again.triggers = Array(again.triggers.prefix(1))
        let second = prefs.add(again, triggers: [again.triggers[0].id], servers: Set(again.servers.map(\.id)), for: nil)
        #expect(prefs.mcpServers.count == 3 && second.servers == 3)
        #expect(prefs.shortcuts.last?.performer == nil)
        #expect(prefs.imps.allSatisfy { Set($0.servers) == Set(prefs.mcpServers.map(\.id)) })
        #expect(prefs.imps.allSatisfy { $0.servers.count == Set($0.servers).count })
    }
}

// MARK: - Imps in kits

extension KitTests {
    static func troupe() -> (prefs: ImpPreferences, pip: ImpProfile) {
        var prefs = ImpPreferences()
        let service = Service(name: "Local", baseURL: "http://localhost:1234/v1", model: "llama-3")
        prefs.ai.add(service)
        var notes = MCPServerConfig(name: "Notes", transport: .stdio, command: "npx", arguments: ["-y", "notes"], environment: ["TOKEN": "sekrit"])
        notes.id = UUID()
        prefs.mcpServers = [notes]
        var pip = ImpProfile(name: "Pip", hue: 0.57, favoriteHue: 0.9, scale: 1.35, personality: "Dry wit, short answers.",
                             brain: Brain(service: service.id, model: "qwen-2"))
        pip.instructions = "Reply in haiku."
        pip.usesShell = false
        pip.setUses(.senses, false)
        pip.setUses(.computer, true)
        pip.exchangesSent = 7
        pip.sendsToolCalls = false
        pip.servers = [notes.id]
        prefs.imps = [.waiting, pip]
        prefs.shortcuts.append(Shortcut(name: "Pip's key", hotkey: Hotkey(parsing: "ctrl+cmd+P"), performer: pip.id, steps: [Step(.ask, value: "Hello")]))
        prefs.shortcuts.append(Shortcut(name: "Everyone", trigger: .starter(.wake), steps: [Step(.ask, value: "Shared")]))
        return (prefs, pip)
    }

    static func chat(_ title: String) -> Chat {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var memory = ChatMemory()
        memory.remember([.user("Hi"), .assistant(nil, toolCalls: [ToolCall(id: "c1", name: "x", arguments: "{}")]), .tool(id: "c1", content: "ok"), .assistant("Hello")])
        let step = ChatTurn.Step(icon: "terminal", title: "ls", request: "ls", response: "a b", failed: false)
        return Chat(title: title, created: date, turns: [ChatTurn(date: date, request: "Hi", reply: "Hello", steps: [step], via: .typed)], memory: memory)
    }

    @Test func anImpRoundTrips() throws {
        let (prefs, pip) = Self.troupe()
        let kit = Kit.exporting(imps: [pip.id], from: prefs, name: "Pip")
        let text = kit.json()
        #expect(!text.contains("sekrit") && !text.contains(pip.id.uuidString))
        let back = try Kit.parse(text)
        #expect(back.problems.isEmpty && back.imps.count == 1 && back.servers.map(\.name) == ["Notes"] && back.triggers.isEmpty)

        var target = prefs                                         // the same Mac: the name is taken, the service matches
        let added = target.add(back, imps: Set(back.imps.map(\.id)), triggers: [], servers: [], for: nil)
        #expect(added.imps.count == 1 && added.servers == 1 && added.needingSecrets.count == 0)   // Notes already there: reused
        let new = try #require(target.imps.last)
        #expect(new.id != pip.id && new.name == "Pip 2" && new.isActive == false && target.imps.count == 3)
        #expect(new.hue == pip.hue && new.favoriteHue == pip.favoriteHue && new.scale == pip.scale && new.personality == pip.personality)
        #expect(new.instructions == pip.instructions && new.usesShell == false && new.exchangesSent == 7 && new.remembersToolCalls == false)
        #expect(ImpToolGroup.allCases.allSatisfy { new.uses($0) == pip.uses($0) } && new.uses(.computer) && !new.uses(.senses))
        #expect(new.brain == pip.brain)
        #expect(new.servers == pip.servers && target.mcpServers.count == 1)
        let mine = target.shortcuts(of: new.id)
        #expect(mine.count == 1 && mine[0].name == "Pip's key" && mine[0].keys == Hotkey(parsing: "ctrl+cmd+P") && mine[0].id != prefs.shortcuts[0].id)
        #expect(target.sharedShortcuts.count == prefs.sharedShortcuts.count)      // the shared trigger wasn't in this kit
        #expect(target.shortcuts(of: pip.id).count == 1)
    }

    @Test func importsToAnotherMacWithFreshServersAndSecretsBlank() throws {
        let (prefs, pip) = Self.troupe()
        let kit = try Kit.parse(Kit.exporting(imps: [pip.id], from: prefs).json())
        var other = ImpPreferences()
        let added = other.add(kit, imps: Set(kit.imps.map(\.id)), triggers: [], servers: [], for: nil)
        let new = try #require(other.imps.last)
        #expect(new.name == "Pip 2" && other.imps.count == 2)          // the first Imp of a Mac is Pip too
        #expect(added.needingSecrets.count == 1 && other.mcpServers.map(\.environment) == [["TOKEN": ""]])
        #expect(new.servers == other.mcpServers.map(\.id))
        #expect(other.ai.services.isEmpty)                                         // never auto-adds a service
        #expect(new.brain == nil)                                                  // so it follows the default
    }

    @Test func matchesTheServiceByAddressElseWarns() throws {
        let (prefs, pip) = Self.troupe()
        let kit = try Kit.parse(Kit.exporting(imps: [pip.id], from: prefs).json())
        #expect(kit.imps[0].brain == KitBrain(model: "qwen-2", serviceName: "Local", baseURL: "http://localhost:1234/v1"))
        // A different Mac with the same service under another name, a slash and other case.
        var other = ImpPreferences()
        other.ai.add(Service(name: "My LM Studio", baseURL: "HTTP://localhost:1234/v1/", model: "qwen-2"))
        #expect(kit.warnings(services: other.ai.services).allSatisfy { $0.kind != .brainMissing })
        other.add(kit, imps: Set(kit.imps.map(\.id)), triggers: [], servers: [], for: nil)
        #expect(other.imps.last?.brain == Brain(service: other.ai.services[0].id, model: ""))    // its model is the service's own
        // Nothing matches: a warning, and the default service.
        let none = kit.warnings(services: [])
        let warning = try #require(none.first { $0.kind == .brainMissing })
        #expect(warning.item == kit.imps[0].id)
        #expect(warning.text == "Uses qwen-2 on Local, which you haven't added: it will use your default until you set one")
        #expect(kit.warnings().allSatisfy { $0.kind != .brainMissing })           // services unknown: no claim
    }

    @Test func warnsWhenComputerControlIsOn() throws {
        let (prefs, pip) = Self.troupe()
        let kit = try Kit.parse(Kit.exporting(imps: [pip.id], from: prefs).json())
        #expect(kit.warnings().contains { $0.kind == .computerControl && $0.item == kit.imps[0].id })
        let calm = try Kit.parse(#"{"imps": [{"name": "Calm"}]}"#)
        #expect(calm.warnings().isEmpty)
    }

    @Test func namesStayUnique() {
        #expect(ImpProfile.uniqueName("Pip", avoiding: ["Imp"]) == "Pip")
        #expect(ImpProfile.uniqueName("Pip", avoiding: ["pip", "Pip 2"]) == "Pip 3")
        #expect(!ImpProfile.uniqueName("  ", avoiding: []).isEmpty)
    }

    @Test func chatsRoundTripIntoTheNewImp() throws {
        let (base, pip) = Self.troupe()
        var prefs = base
        let chat = Self.chat("Greeting")
        var withSender = Self.chat("Other")
        withSender.turns[0].sender = ChatTurn.Sender(id: UUID(), name: "Nib", hue: 0.3)
        let peerChat = Chat(title: "With Nib", turns: [ChatTurn(request: "x")], peer: UUID())
        let kit = Kit.exporting(imps: [pip.id], from: prefs, chats: [pip.id: [chat, withSender, peerChat]])
        let back = try Kit.parse(kit.json())
        #expect(back.imps[0].chats.count == 2)                                    // the chat between Imps stays home
        let got = try #require(back.imps[0].chats.first { $0.title == "Greeting" })
        #expect(got.id != chat.id && got.turns[0].id != chat.turns[0].id)
        #expect(got.turns.map(\.request) == ["Hi"] && got.turns[0].reply == "Hello" && got.turns[0].via == .typed)
        #expect(got.turns[0].steps.map(\.title) == ["ls"] && got.turns[0].steps[0].response == "a b")
        #expect(got.created == chat.created && got.updated == chat.updated)
        #expect(got.memory.messages == chat.memory.messages && got.memory.messages.count == 4)

        let added = prefs.add(back, imps: Set(back.imps.map(\.id)), triggers: [], servers: [], for: nil)
        let imported = try #require(added.imps.first)
        #expect(imported.chats.count == 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kit-chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var history = ChatHistory(folder: folder)
        for c in imported.chats { history.adopt(c) }
        let reopened = ChatHistory(folder: folder)
        #expect(reopened.chats.count == 2 && reopened.savedChats().contains { $0.title == "Greeting" && $0.memory.messages.count == 4 })

        // Left out when the review says so.
        var again = prefs
        #expect(again.add(back, imps: Set(back.imps.map(\.id)), triggers: [], servers: [], for: nil, withChats: false).imps[0].chats.isEmpty)
        // Chats are bigger than a link or address may carry.
        #expect(back.link == nil)
    }

    @Test func exportAllCarriesSharedTriggers() throws {
        let (prefs, _) = Self.troupe()
        let kit = Kit.exporting(imps: Set(prefs.imps.map(\.id)), from: prefs, shared: true)
        #expect(kit.imps.count == 2 && kit.triggers.map(\.name) == ["Everyone"])
        let back = try Kit.parse(kit.json())
        #expect(back.imps.map(\.name) == ["Pip", "Pip"] && back.triggers.map(\.name) == ["Everyone"])
        // Servers only the Imps use are the kit's tools, once.
        #expect(back.servers.map(\.name) == ["Notes"] && back.imps[1].servers == [back.servers[0].id])
    }

    @Test func serversSharedByNameStayDistinct() throws {
        var a = MCPServerConfig(name: "Tool", transport: .stdio, command: "a"), b = MCPServerConfig(name: "Tool", transport: .stdio, command: "b")
        a.id = UUID(); b.id = UUID()
        let kit = Kit(servers: [a, b], imps: [KitImp(name: "X", servers: [b.id])])
        let back = try Kit.parse(kit.json())
        #expect(back.servers.count == 2)
        let used = try #require(back.servers.first { $0.id == back.imps[0].servers.first })
        #expect(used.commandLine == "b")
    }

    @Test func readsDefaultsAndIgnoresUnknownFields() throws {
        let kit = try Kit.parse(#"""
        {"future": {"x": 1}, "imps": [
          { "name": "Bare", "mood": "grumpy", "tools": {"personality": false, "telepathy": true}, "brain": {"model": "m", "extra": 1} },
          { "personality": "no name" },
          { "name": "Wired", "mcpServers": ["Gone"], "triggers": [{"on": "teleport"}] } ] }
        """#)
        let bare = kit.imps[0]
        #expect(bare.hue == 0 && bare.scale == 1 && bare.personality == "" && bare.instructions == nil && bare.usesShell && bare.sendsToolCalls)
        #expect(bare.uses(.senses) && !bare.uses(.personality) && !bare.uses(.computer))
        #expect(bare.brain == KitBrain(model: "m"))
        #expect(kit.imps.count == 2 && kit.imps[1].name == "Wired")
        #expect(kit.problems.count == 3 && kit.problems.contains { $0.hasPrefix("Imp 2:") } && kit.problems.contains { $0.contains("“Gone”") })
        var prefs = ImpPreferences()
        prefs.add(kit, imps: Set(kit.imps.map(\.id)), triggers: [], servers: [], for: nil)
        #expect(prefs.imps.suffix(2).map(\.name) == ["Bare", "Wired"] && prefs.imps[1].brain == Brain(service: nil, model: "m"))
    }

    @Test func clampsWhatFilesSay() throws {
        let kit = try Kit.parse(#"{"imps": [{"name": "Big", "hue": 7, "scale": 100, "exchangesSent": 100000}]}"#)
        #expect(kit.imps[0].hue == 1 && kit.imps[0].scale == 2 && kit.imps[0].exchangesSent == ChatMemory.storedExchanges)
        let many = (0...Kit.maxImps).map { #"{"name": "I\#($0)"}"# }.joined(separator: ",")
        #expect(throws: KitError.tooMany("Imps", Kit.maxImps)) { try Kit.parse(#"{"imps": [\#(many)]}"#) }
    }

    // MARK: Shape

    @Test func aKitCarriesNoVersionNumber() throws {
        let plain = Kit(triggers: [Shortcut(name: "T", trigger: .click(2), steps: [Step(.ask, value: "Hi")])])
        #expect(!plain.json().contains("\"imp\""))
        let (prefs, pip) = Self.troupe()
        let withImp = Kit.exporting(imps: [pip.id], from: prefs)
        #expect(withImp.json().hasPrefix("{\n  \"imps\""))
    }

    @Test func recordsTheWritingApp() throws {
        var kit = Kit(imps: [KitImp(name: "A")])
        #expect(!kit.json().contains("\"app\""))
        kit.app = "1.7.0"
        #expect(kit.json().hasPrefix("{\n  \"app\": \"1.7.0\","))
        #expect(try Kit.parse(kit.json()).app == "1.7.0")
    }

    @Test func readsTriggersAndTools() throws {
        let kit = try Kit.parse(Self.full)
        #expect(kit.imps.isEmpty && kit.triggers.count == 3)
    }

    @Test func readsImpsAndTheWritingApp() throws {
        let kit = try Kit.parse(#"{"app": "9.9", "imps": [{"name": "A"}]}"#)
        #expect(kit.imps.map(\.name) == ["A"] && kit.app == "9.9")
    }

    @Test func fileLimitIsBiggerThanTheDefault() throws {
        let padding = String(repeating: "a", count: Kit.maxBytes)
        let text = #"{"imps": [{"name": "A", "personality": ""# + padding + #""}]}"#
        #expect(throws: KitError.tooLarge) { try Kit.parse(text) }
        #expect(try Kit.parse(text, limit: Kit.maxFileBytes).imps.count == 1)
    }
}

extension KitSource {
    var textValue: String {
        get throws { if case .text(let t) = self { return t } else { throw KitError.notAKit } }
    }
}
