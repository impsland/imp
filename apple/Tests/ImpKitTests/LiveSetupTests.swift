// Live API (opt-in): IMP_LIVE_TESTS=1 swift test --filter LiveSetup

import Foundation
import Testing
@testable import ImpKit

/// The Imp setting itself up with a real model: the tools as the Mac offers them, run against real
/// preferences (what `OwnToolHost` does, without the app around it).
@Suite(.enabled(if: LiveEnv.values != nil), .serialized) struct LiveSetupTests {
    actor Host: ToolProvider {
        var prefs: ImpPreferences
        let imp: UUID
        private(set) var calls: [(name: String, arguments: String, result: String)] = []

        init() {
            var p = ImpPreferences.withWaitingImp()
            let pip = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: Persona.newcomer(named: "Pip"))
            p.imps = [pip]
            prefs = p; imp = pip.id
        }

        var playable: [String] {
            prefs.originals(for: imp).filter(\.isEnabled).map(\.title)
        }

        nonisolated func tools() async -> [ToolSpec] {
            await OwnTools.specs([.animations, .triggers, .tools], animations: playable, imps: [], browser: true)
        }

        func call(_ name: String, arguments: String) async throws -> String {
            let args = (try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments)) ?? [:]
            let result: String
            do { result = try run(name, args) } catch let e as ToolArgumentError { result = "Error: \(e.message)" }
            calls.append((name, arguments, result))
            return result
        }

        private func run(_ name: String, _ args: JSONValue) throws -> String {
            switch name {
            case OwnTools.makeAnimation:
                var problems: [String] = []
                guard var made = MadeAnimation(kit: args, problems: &problems) else { throw ToolArgumentError(problems.joined(separator: " ")) }
                made.name = prefs.uniqueAnimationName(made.name, imp: imp)
                prefs.save(made, for: imp)
                return "Made “\(made.title)” for you."
            case OwnTools.addTrigger:
                let s = try Shortcut(tool: args, imp: imp)
                self.prefs.shortcuts.append(s)
                return "Added " + s.toolDescription()
            case OwnTools.listTriggers:
                return prefs.shortcuts.map { $0.toolDescription() }.joined(separator: "\n")
            case OwnTools.play: return "Playing."
            case OwnTools.showAnimation: return "Your own animations: \(prefs.ownAnimations(of: imp).map(\.title))."
            default: return "Done."
            }
        }
    }

    static func system(_ extra: String = "") -> String {
        let p = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: Persona.newcomer(named: "Pip"))
        return p.systemPrompt.replacingOccurrences(of: Workspace.directory(for: p.id).path, with: "/tmp/pip") + extra
    }

    /// The field case: it makes an animation, then a trigger that plays it, in one go.
    @Test func makesAnAnimationAndATriggerThatPlaysIt() async throws {
        let live = try LiveEnv.client()
        let host = Host()
        let specs = await host.tools()
        let size = specs.reduce(0) { $0 + $1.name.count + $1.description.count + $1.inputSchema.jsonString.count } + Self.system().count
        print("live setup: initial context ≈ \(size) characters (≈ \(size / 4) tokens), \(specs.count) tools")
        let agent = Agent(client: live.client, model: live.model, tools: host)
        let (reply, _) = try await agent.run([.system(Self.system()), Briefing.message(
            "Make a delighted little animation called hn_delight, and a trigger: whenever I open news.ycombinator.com, just play it (no thinking).")])
        let calls = await host.calls
        print("live setup calls:\n" + calls.map { "\($0.name) \($0.arguments)\n  → \($0.result)" }.joined(separator: "\n") + "\nreply: \(reply)")
        let prefs = await host.prefs, imp = host.imp
        let made = try #require(prefs.ownAnimations(of: imp).first, "no animation made")
        let trigger = try #require(prefs.shortcuts.first, "no trigger made")
        #expect(trigger.trigger.event == .website && trigger.steps.map(\.act) == [.play])
        #expect(trigger.steps.first?.animationName.flatMap { prefs.ref(named: $0, imp: imp) } == .custom(made.id))
        #expect(!calls.contains { $0.result.hasPrefix("Error") && $0.name == OwnTools.addTrigger && $0.result.contains("Unknown animation") })
    }

    /// The words of the first run's prompt in `language`, from the String Catalog.
    static func presetPrompt(_ language: String) throws -> String {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Localization/Localizable.xcstrings")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        let localizations = try #require(strings["onboarding.prompt"]?["localizations"] as? [String: [String: [String: String]]])
        return try #require(localizations[language]?["stringUnit"]?["value"])
    }

    /// The first run's plain prompt, in everyday words: five animations, and a click that opens the text box.
    @Test(arguments: ["en", "es"]) func thePlainFirstRunPromptSetsTheImpUp(language: String) async throws {
        let live = try LiveEnv.client()
        let host = Host()
        let agent = Agent(client: live.client, model: live.model, tools: host)
        let (reply, _) = try await agent.run([.system(Self.system()), Briefing.message(try Self.presetPrompt(language))])
        let calls = await host.calls
        print("live first run (\(language)) calls:\n" + calls.map { "\($0.name) \($0.arguments)\n  -> \($0.result)" }.joined(separator: "\n") + "\nreply: \(reply)")
        let prefs = await host.prefs, imp = host.imp
        #expect(prefs.ownAnimations(of: imp).count == 5, "animations: \(prefs.ownAnimations(of: imp).count)")
        let opens = prefs.shortcuts.filter { $0.trigger.event == .click && $0.steps.contains { $0.act == .open && $0.value == "text_box" } }
        #expect(opens.count == 1, "triggers: \(prefs.shortcuts.map { $0.toolDescription() })")
    }

    /// Plain everyday requests, one turn each: which tool the model reaches for first.
    @Test(arguments: [
        ("When I click on you, open the box where I type.", OwnTools.addTrigger),
        ("Every morning at 9 remind me to drink water.", OwnTools.addTrigger),
        ("Connect my Google Calendar so you can see my meetings.", OwnTools.addTool),
        ("Make yourself look sleepy.", OwnTools.setTraits),
        ("Open the Rust website for me.", ShellTool.name),
        ("Ask Bo what he is doing.", OwnTools.message),
    ]) func plainRequestsPickTheRightTool(request: String, expected: String) async throws {
        let live = try LiveEnv.client()
        var specs = await Host().tools()
        specs += OwnTools.specs([.personality, .look], animations: [], imps: ["Bo"], browser: true)
        specs += await ShellTool(directory: URL(fileURLWithPath: "/tmp/pip")).tools()
        let reply = try await live.client.chat(model: live.model, messages: [.system(Self.system()), Briefing.message(request)], tools: specs)
        let first = reply.toolCalls.first?.name
        print("live plain request: \(request) expected \(expected) got \(first ?? "no tool call")")
        #expect(first == expected, "\(request): got \(first ?? "no tool call")")
    }

    /// Asked from a device that isn't marked Mine: no tools, and it says how to change that.
    @Test func withoutToolsItSaysWhyAndHow() async throws {
        let live = try LiveEnv.client()
        let note = "\n\n" + Briefing.untrusted(device: "Anna's iPhone", home: "Studio Mac")
        let reply = try await live.client.chat(model: live.model, messages: [.system(Self.system(note)),
                                                                          .user("Ask Bo, my other Imp on the Mac, what time it is there.")]).text
        print("live untrusted reply: \(reply)")
        #expect(reply.contains("Mine"), "got: \(reply)")
    }
}
