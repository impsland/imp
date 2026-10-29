import Foundation
import Testing
@testable import ImpKit

@Suite struct KitTests {
    static let full = #"""
    { "imp": 1, "name": "Morning helper", "about": "Starts the day.",
      "triggers": [
        { "name": "Summarize", "when": {"kind": "keys", "keys": "ctrl+cmd+S"}, "prompt": "Summarize this.", "with_clipboard": true },
        { "name": "Low battery", "when": {"kind": "battery", "number": 15}, "only_if": [{"kind": "app", "text": "Safari"}, {"kind": "hours", "text": "22:00-07:00"}],
          "do": "chat" },
        { "name": "Nine", "when": {"kind": "time", "text": "9:05"}, "prompt": "Plan my day." }
      ],
      "mcpServers": {
        "Memory": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"] },
        "GitHub": { "command": "npx", "args": ["-y", "server-github"], "env": {"GITHUB_TOKEN": "ghp_secret"} },
        "Remote": { "url": "https://mcp.example.com/mcp?key=abc", "headers": {"Authorization": "Bearer secret"} }
      } }
    """#

    @Test func parsesAFullKit() throws {
        let kit = try Kit.parse(Self.full)
        #expect(kit.name == "Morning helper" && kit.about == "Starts the day.")
        #expect(kit.triggers.map(\.name) == ["Summarize", "Low battery", "Nine"])
        #expect(kit.triggers[0].keys == Hotkey(parsing: "ctrl+cmd+S") && kit.triggers[0].usesClipboard)
        #expect(kit.triggers[1].trigger.kind == .battery && kit.triggers[1].conditions.count == 2 && kit.triggers[1].command == .chat)
        #expect(kit.triggers[2].trigger.minuteOfDay == 9 * 60 + 5)
        #expect(kit.servers.map(\.name) == ["GitHub", "Memory", "Remote"])
        #expect(kit.problems.isEmpty)
    }

    @Test func badItemsDoNotSinkTheKit() throws {
        let kit = try Kit.parse(#"""
        {"imp": 1, "triggers": [
            {"name": "Good", "when": {"kind": "wake"}, "prompt": "Hi"},
            {"name": "Bad kind", "when": {"kind": "teleport"}, "prompt": "x"},
            {"name": "No when", "prompt": "x"}],
         "mcpServers": {"Fine": {"command": "uvx mcp-server-fetch"}, "Broken": {"args": ["x"]}, "Text": "npx foo"}}
        """#)
        #expect(kit.triggers.map(\.name) == ["Good"])
        #expect(kit.servers.map(\.name) == ["Fine"])
        #expect(kit.problems.count == 4)
        #expect(kit.problems.contains { $0.contains("Bad kind") && $0.contains("teleport") })
        #expect(kit.problems.contains { $0.hasPrefix("Tool “Broken”") })
    }

    @Test func aKitOfOnlyBadItemsIsAnError() {
        #expect(throws: KitError.self) { try Kit.parse(#"{"imp": 1, "triggers": [{"when": {"kind": "teleport"}}]}"#) }
        #expect(throws: KitError.empty) { try Kit.parse(#"{"imp": 1, "name": "Nothing"}"#) }
    }

    @Test func readsAPlainMCPSnippet() throws {
        let config = try Kit.parse(#"{"mcpServers": {"fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}}}"#)
        #expect(config.triggers.isEmpty && config.servers.map(\.name) == ["fetch"])
        #expect(try Kit.parse("npx -y @modelcontextprotocol/server-memory").servers.first?.name == "Memory")
        #expect(try Kit.parse("https://mcp.example.com/mcp").servers.first?.transport == .http)
        // A server named like a wrapper key still reads.
        #expect(try Kit.parse(#"{"imp": 1, "mcpServers": {"mcp": {"command": "foo"}}}"#).servers.map(\.name) == ["mcp"])
    }

    @Test func readsASingleTriggerOrAList() throws {
        let one = try Kit.parse(#"{"name": "Hello", "when": {"kind": "start"}, "prompt": "Say hi."}"#)
        #expect(one.triggers.count == 1 && one.triggers[0].performer == nil && one.servers.isEmpty)
        let list = try Kit.parse(#"[{"when": {"kind": "wake"}, "prompt": "a"}, {"when": {"kind": "hot"}, "prompt": "b"}, {"nope": 1}]"#)
        #expect(list.triggers.count == 2 && list.problems.count == 1)
    }

    @Test func refusesNewerVersionsAndNonKits() {
        #expect(throws: KitError.newerVersion(2)) { try Kit.parse(#"{"imp": 2, "triggers": []}"#) }
        #expect(throws: KitError.notAKit) { try Kit.parse(#"{"imp": "one"}"#) }
        #expect(throws: KitError.notAKit) { try Kit.parse(#"{"colour": "red"}"#) }
        #expect(throws: KitError.empty) { try Kit.parse("  \n ") }
    }

    @Test func capsSizeAndCounts() throws {
        let big = #"{"imp": 1, "name": ""# + String(repeating: "a", count: Kit.maxBytes) + #""}"#
        #expect(throws: KitError.tooLarge) { try Kit.parse(big) }
        let triggers = Array(repeating: #"{"when": {"kind": "wake"}, "prompt": "x"}"#, count: Kit.maxTriggers + 1).joined(separator: ",")
        #expect(throws: KitError.tooMany("triggers", Kit.maxTriggers)) { try Kit.parse("[\(triggers)]") }
        let servers = (0...Kit.maxServers).map { #""s\#($0)": {"command": "x\#($0)"}"# }.joined(separator: ",")
        #expect(throws: KitError.tooMany("tools", Kit.maxServers)) { try Kit.parse(#"{"imp": 1, "mcpServers": {\#(servers)}}"#) }
    }

    @Test func warnsAboutCodeSecretsAndKeys() throws {
        let kit = try Kit.parse(Kit.parse(Self.full).json())      // as shared: secrets blanked
        let taken = Shortcut(name: "Mine", hotkey: Hotkey(parsing: "ctrl+cmd+S"), prompt: "x")
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
        [{"when": {"kind": "keys", "keys": "ctrl+opt+K"}, "prompt": "a"}, {"when": {"kind": "keys", "keys": "⌃⌥K"}, "prompt": "b"}]
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
                #expect(a.name == b.name && a.hotkey == b.hotkey && a.prompt == b.prompt && a.usesClipboard == b.usesClipboard)
                #expect(a.trigger == b.trigger && a.conditions == b.conditions && a.command == b.command)
            }
            #expect(back.servers.count == kit.servers.count)
            for (a, b) in zip(kit.servers, back.servers) {
                #expect(a.name == b.name && a.transport == b.transport && a.commandLine == b.commandLine)
                #expect(a.environment.mapValues { _ in "" } == b.environment && a.headers.mapValues { _ in "" } == b.headers)
            }
        }
    }

    @Test func everyKindOfTriggerRoundTrips() throws {
        let kinds = Trigger.Kind.allCases.filter { $0 != .keys && $0 != .hours }
        var shortcuts = kinds.map { Shortcut(name: "\($0)", prompt: "p", usesClipboard: false, trigger: .starter($0)) }
        shortcuts.append(Shortcut(name: "off", prompt: "q", usesClipboard: false, trigger: Trigger(.offline, flag: false)))
        shortcuts.append(Shortcut(name: "keys", hotkey: Hotkey(parsing: "⌃⌥⇧⌘Space"), prompt: "k"))
        shortcuts.append(Shortcut(name: "dash", hotkey: Hotkey(parsing: "⌘⌥-"), prompt: "d", conditions: Trigger.Kind.allCases.filter(\.isCondition).map { .starter($0) }))
        let back = try Kit.parse(Kit(triggers: shortcuts).json()).triggers
        #expect(back.count == shortcuts.count)
        for (a, b) in zip(shortcuts, back) { #expect(a.trigger == b.trigger && a.conditions == b.conditions && a.hotkey == b.hotkey, "\(a.name)") }
    }

    @Test func exportIsOrderedAndReadable() {
        let kit = Kit(name: "K", triggers: [Shortcut(name: "T", prompt: "Do it", trigger: .clicks(2))],
                      servers: [MCPServerConfig(name: "S", transport: .stdio, command: "npx", arguments: ["-y", "pkg"], environment: ["KEY": "secret"])])
        let text = kit.json()
        #expect(text.hasPrefix("{\n  \"imp\": 1,\n  \"name\": \"K\","))
        #expect(text.contains("\"env\": {\n        \"KEY\": \"\"\n      }"))
        #expect(!text.contains("secret"))
    }

    @Test func linkOnlyWhenShort() throws {
        let small = Kit(triggers: [Shortcut(name: "T", prompt: "Hi", trigger: .clicks(2))])
        let link = try #require(small.link)
        #expect(link.hasPrefix("imp://add?kit=") && !link.dropFirst(14).contains(where: { "+/=".contains($0) }))
        #expect(try Kit.parse(try KitSource.link(link).textValue).triggers.first?.name == "T")
        let huge = Kit(triggers: [Shortcut(name: "T", prompt: String(repeating: "word ", count: 600), trigger: .clicks(2))])
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
        let json = #"{"imp":1,"triggers":[{"when":{"kind":"wake"},"prompt":"é?&+/"}]}"#
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
        #expect(try KitSource(input: #"{"imp": 1}"#) == .text(#"{"imp": 1}"#))
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

        // The same kit again: servers are reused, not doubled; "every Imp" switches them on for all.
        var again = try Kit.parse(Kit.parse(Self.full).json())
        again.triggers = Array(again.triggers.prefix(1))
        let second = prefs.add(again, triggers: [again.triggers[0].id], servers: Set(again.servers.map(\.id)), for: nil)
        #expect(prefs.mcpServers.count == 3 && second.servers == 3)
        #expect(prefs.shortcuts.last?.performer == nil)
        #expect(prefs.imps.allSatisfy { Set($0.servers) == Set(prefs.mcpServers.map(\.id)) })
        #expect(prefs.imps.allSatisfy { $0.servers.count == Set($0.servers).count })
    }
}

extension KitSource {
    var textValue: String {
        get throws { if case .text(let t) = self { return t } else { throw KitError.notAKit } }
    }
}
