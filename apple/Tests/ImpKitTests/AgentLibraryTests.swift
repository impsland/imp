import Foundation
import ImpCore
import Testing
@testable import ImpKit

/// Skills and custom commands of an `.agents` folder as the chats use them. A folder of the test's own, never the person's.
@Suite struct AgentLibraryTests {
    private struct Home {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imp-library-\(UUID().uuidString)")
        var library: AgentLibrary { AgentLibrary(configDir: root.appendingPathComponent(".config/imp"), homeDir: root) }

        init(skills: [String: String] = [:], commands: [String: String] = [:]) throws {
            for (name, text) in skills { try write(".agents/skills/\(name)/SKILL.md", text) }
            for (name, text) in commands { try write(".agents/commands/\(name).md", text) }
        }

        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Answers like a computer with one file and a shell that prints what it was asked for.
    private struct Fake: CommandWorld {
        var deny = false
        func shell(_ line: String) async throws -> String {
            if deny { throw CommandFailure("Not allowed: shell \(line).") }
            return "<\(line)>\n"
        }
        func read(_ path: String) async throws -> String? { path == "a.rs" ? "fn a() {}\n" : nil }
    }

    private let notes = "---\nname: notes\ndescription: Take notes\n---\nStep one."

    // MARK: Commands

    @Test func theListHasUsageAndWords() throws {
        let home = try Home(commands: ["review": "---\ndescription: Review it\n---\nLook at $1", "plain": "Say hi."])
        defer { home.remove() }
        let list = home.library.commands()
        #expect(list.map(\.name) == ["plain", "review"])
        #expect(list.map(\.usage) == ["/plain", "/review ARGUMENTS"])
        #expect(list.map(\.about) == ["Say hi.", "Review it"])
        #expect(list.map(\.takesArguments) == [false, true])
    }

    @Test func typingASlashFiltersThePrefixFirst() {
        func entry(_ name: String) -> CommandEntry { CommandEntry(name: name, usage: "/\(name)", about: "", takesArguments: false) }
        let all = [entry("review"), entry("preview"), entry("deploy")]
        #expect(SlashSuggestions.matches("/", in: all).map(\.name) == ["review", "preview", "deploy"])
        #expect(SlashSuggestions.matches("/re", in: all).map(\.name) == ["review", "preview"])
        #expect(SlashSuggestions.matches("/REV", in: all).map(\.name) == ["review", "preview"])
        #expect(SlashSuggestions.matches("/rev", in: all).map(\.name) == ["review", "preview"])
        #expect(SlashSuggestions.matches("/pre", in: all).map(\.name) == ["preview"])
        #expect(SlashSuggestions.matches("/zzz", in: all).isEmpty)
        #expect(SlashSuggestions.matches("review", in: all).isEmpty, "not a command line")
        #expect(SlashSuggestions.matches("/review x", in: all).isEmpty, "the arguments are being typed")
        #expect(SlashSuggestions.completion(of: entry("review")) == "/review")
        #expect(SlashSuggestions.completion(of: CommandEntry(name: "go", usage: "/go ARGUMENTS", about: "", takesArguments: true)) == "/go ")
    }

    @Test func aTypedLineBecomesAPlanThatTheWorldFillsIn() async throws {
        let home = try Home(commands: ["go": "---\nagent: review\nmodel: ollama/qwen3\nsubtask: true\n---\nSee $1: !`git status` and @a.rs and @nope.rs"])
        defer { home.remove() }
        let plan = try #require(home.library.plan("/go x"))
        #expect(plan.name == "go" && plan.agent == "review" && plan.model == "ollama/qwen3" && plan.subtask)
        #expect(CommandSettings(plan) == CommandSettings(agent: "review", model: "ollama/qwen3", subtask: true))
        let text = try await home.library.prepare(plan, world: Fake())
        #expect(text == "See x: <git status> and <file path=\"a.rs\">\nfn a() {}\n</file> and @nope.rs")
        #expect(home.library.plan("/unknown") == nil)
        #expect(home.library.plan("go") == nil)
    }

    @Test func aCommandThatIsNotAllowedStopsTheMessage() async throws {
        let home = try Home(commands: ["st": "!`git status`"])
        defer { home.remove() }
        let plan = try #require(home.library.plan("/st"))
        await #expect(throws: CommandFailure("Not allowed: shell git status.")) {
            try await home.library.prepare(plan, world: Fake(deny: true))
        }
    }

    @Test func noShellIsTheCoresSentence() {
        #expect(noShell("ls").message == "`ls` can't run here: this device has no shell.")
    }

    // MARK: Skills

    @Test func skillsAreListedAndRead() async throws {
        let home = try Home(skills: ["notes": notes])
        defer { home.remove() }
        #expect(home.library.skillsPrompt.contains("- notes: Take notes"))
        let tools = try #require(home.library.skillTools)
        let specs = await tools.tools()
        #expect(specs.map(\.name) == [OwnTools.useSkill])
        let text = try await tools.call(OwnTools.useSkill, arguments: #"{"name":"notes"}"#)
        #expect(text.contains("Step one.") && !text.contains("description:"))
        #expect(try await tools.call(OwnTools.useSkill, arguments: #"{"name":"nope"}"#).contains("there is no skill nope"))
    }

    @Test func withoutSkillsThereIsNoToolAndNoWords() throws {
        let home = try Home()
        defer { home.remove() }
        #expect(home.library.skillsPrompt.isEmpty)
        #expect(home.library.skillTools == nil)
    }

    @Test func theSkillToolIsInTheSkillsGroupAndCanBeSwitchedOff() async throws {
        let home = try Home(skills: ["notes": notes])
        defer { home.remove() }
        let entry = try #require(ToolRegistry.entry(named: OwnTools.useSkill))
        #expect(entry.group == ToolRegistry.ownGroupID(.skills) && entry.id == ToolRegistry.ownID(.skills, tool: OwnTools.useSkill))
        #expect(OwnTools.group(of: OwnTools.useSkill) == .skills)
        let tools = try #require(home.library.skillTools)
        #expect(await ToolSet([tools]).tools().map(\.name) == [OwnTools.useSkill])
        let off = ToolSelection(groupsOff: [ToolRegistry.ownGroupID(.skills)])
        #expect(await ToolSet([tools], selection: off).tools().isEmpty)
        let one = ToolSelection(toolsOff: [entry.id])
        #expect(await ToolSet([tools], selection: one).tools().isEmpty)
    }
}
