import Foundation
import ImpCore

/// The skills and custom commands of an `.agents` folder as the chats use them (`docs/apps/skills-commands.md`).
/// The rules are the core's (`imp_engine::agents`, `imp_engine::custom`), the same as the `imp` chat has: this
/// only reads the folder through them. The Mac reads `~/.agents`, the iPhone its own folder.
public struct AgentLibrary: Sendable {
    let paths: ConfigPaths

    init(paths: ConfigPaths) { self.paths = paths }

    public init(configDir: URL, homeDir: URL) {
        paths = ConfigPaths(configDir: configDir.path, homeDir: homeDir.path)
    }

    // MARK: Skills

    /// What goes after who the Imp is in its system text: the list of skills. Empty without skills.
    public var skillsPrompt: String { ImpCore.skillsPrompt(paths: paths) }

    /// The `use_skill` tool for the skills there are, nil without any.
    public var skillTools: SkillTools? { skillsTool(paths: paths) == nil ? nil : SkillTools(paths: paths) }

    // MARK: Commands

    /// The custom commands, by name.
    public func commands() -> [CommandEntry] { commandsList(paths: paths) }

    /// What a typed line is as a command (nil for any other line).
    public func plan(_ line: String) -> CommandPlan? { commandPlan(paths: paths, line: line) }

    /// The command's message with its command lines and files resolved by `world`. A command line or a file that
    /// is not allowed, or does not run, stops it: the error is a sentence for the person.
    public func prepare(_ plan: CommandPlan, world: CommandWorld) async throws -> String {
        var answers: [String?] = []
        for piece in plan.pieces {
            switch piece {
            case .text: answers.append(nil)
            case .shell(let line): answers.append(try await world.shell(line))
            case .file(let path): answers.append(try await world.read(path))
            }
        }
        return commandFill(pieces: plan.pieces, answers: answers)
    }
}

/// Who runs a command and how: what its front matter says besides its text.
public struct CommandSettings: Equatable, Sendable {
    /// The Imp that answers instead of the one typed to.
    public var agent: String?
    /// The model for this message only, as `provider/model#variant`.
    public var model: String?
    /// The answer is a conversation of its own: shown, and not kept in the Imp's memory.
    public var subtask: Bool

    public init(agent: String? = nil, model: String? = nil, subtask: Bool = false) {
        self.agent = agent; self.model = model; self.subtask = subtask
    }

    public init(_ plan: CommandPlan) { self.init(agent: plan.agent, model: plan.model, subtask: plan.subtask) }
}

/// What a command's text reaches out to: the shell and the files, each behind the Imp's permission rules.
public protocol CommandWorld: Sendable {
    /// What the command line prints. Throws a `CommandFailure`: not allowed, or it did not run.
    func shell(_ line: String) async throws -> String
    /// The contents of the file `path` names, nil when it names no file (the text then stays as typed).
    func read(_ path: String) async throws -> String?
}

/// Why a command could not be made ready, as a sentence for the person.
public struct CommandFailure: LocalizedError, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A device with no shell: a command line in a command is the core's plain sentence.
public func noShell(_ line: String) -> CommandFailure { CommandFailure(commandNoShell(line: line)) }

/// The commands that match what is typed: a line that is only `/` and the start of a name (while it is
/// still being typed). Names that start with it come first, then names that contain it.
public enum SlashSuggestions {
    public static func matches(_ text: String, in commands: [CommandEntry]) -> [CommandEntry] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let typed = text.dropFirst().lowercased()
        guard !typed.isEmpty else { return commands }
        return commands.filter { $0.name.lowercased().hasPrefix(typed) }
            + commands.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
    }

    /// The line a pick puts in the box: the name, and a space when the command takes arguments.
    public static func completion(of command: CommandEntry) -> String {
        "/\(command.name)" + (command.takesArguments ? " " : "")
    }
}

/// The `use_skill` tool: it reads a skill's text for the model, from the skills the folder has right now.
public struct SkillTools: ToolProvider {
    let paths: ConfigPaths

    public func tools() async -> [ToolSpec] {
        guard let tool = skillsTool(paths: paths),
              let schema = try? JSONValue(jsonString: tool.parametersJson) else { return [] }
        return [ToolSpec(name: tool.name, description: tool.description, inputSchema: schema)]
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard name == OwnTools.useSkill else { throw ToolArgumentError("Unknown tool \(name).") }
        return skillsAnswer(paths: paths, argumentsJson: arguments.isEmpty ? "{}" : arguments)
    }
}
