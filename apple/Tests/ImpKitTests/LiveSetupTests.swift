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
            var p = ImpPreferences()
            let pip = ImpProfile(name: "Pip", hue: 0, favoriteHue: 0.5, personality: Persona.newcomer(named: "Pip"))
            p.imps = [pip]
            prefs = p; imp = pip.id
        }

        var playable: [String] {
            prefs.originals(for: imp).filter(\.isEnabled).map(\.title)
        }

        nonisolated func tools() async -> [ToolSpec] {
            await OwnTools.specs([.body, .setup], animations: playable, imps: [], browser: true)
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
