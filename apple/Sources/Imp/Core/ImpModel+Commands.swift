import Foundation
import ImpCore
import ImpKit

/// A custom command typed in the text box, ready to run (`docs/apps/skills-commands.md`): the plan the core made
/// of the line, the model for this message only, and whether the answer is a conversation of its own.
struct CommandRun {
    var plan: CommandPlan
    /// The Imp that answers: the one the command names with `agent`, else the one typed to.
    var imp: ImpModel
    var brain: Brain?
    var subtask: Bool
}

extension ImpModel {
    /// What the typed line is as a command, with who answers and with what. Nil for any other line. Throws when the
    /// command names an Imp or a model this Mac does not have.
    func commandRun(for line: String) throws -> CommandRun? {
        guard let library = app.config?.agentLibrary, let plan = library.plan(line) else { return nil }
        var brain: Brain?
        if let model = plan.model {
            guard let named = app.config?.brain(forModelRef: model) else {
                throw CommandFailure(String(localized: "The model “\(model)” of /\(plan.name) is not set up on this Mac."))
            }
            brain = named
        }
        var imp = self
        if let agent = plan.agent {
            guard let named = app.imp(agent: agent) else {
                throw CommandFailure(String(localized: "There is no Imp “\(agent)” for /\(plan.name)."))
            }
            imp = named
        }
        return CommandRun(plan: plan, imp: imp, brain: brain, subtask: plan.subtask)
    }

    /// The command's message: its command lines run and its files read behind the Imp's `shell` and `read`
    /// permissions (the person may be asked), in this Imp's own folder.
    func prepared(_ command: CommandRun, typed: String) async throws -> String {
        guard let gate = gate(origin: nil), let library = app.config?.agentLibrary else {
            throw CommandFailure(String(localized: "The configuration is not available."))
        }
        let world = MacCommandWorld(gate: gate, name: profile.name, directory: Workspace.directory(for: id), home: app.config?.homeDir)
        return try await library.prepare(command.plan, world: world)
    }
}

extension AppModel {
    /// The Imp whose agent file is called `name` (or that is called that).
    func imp(agent name: String) -> ImpModel? {
        imps.first { config?.agentName(for: $0.id) == name }
            ?? imps.first { $0.profile.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// The shell and the files of this Mac for a command's text, each behind the Imp's rules (`ToolGate`).
struct MacCommandWorld: CommandWorld {
    let gate: ToolGate
    let name: String
    /// Where commands start and relative paths are: the Imp's own folder.
    let directory: URL
    let home: URL?

    /// How long a command inside a command's text may run.
    static let timeout: TimeInterval = 60

    func shell(_ line: String) async throws -> String {
        let arguments = JSONValue.object(["command": .string(line)]).jsonString
        if let refusal = await gate.refusal(toolID: nil, name: ShellTool.name, arguments: arguments) { throw CommandFailure(refusal) }
        let environment = ShellTool.environment(name: name, directory: directory, baseURL: nil, apiKey: nil, model: nil)
        do {
            let result = try await ShellRunner.run(line, in: directory, environment: environment, timeout: Self.timeout)
            if result.timedOut { throw CommandFailure(String(localized: "`\(line)` took longer than a minute.")) }
            return result.output
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure(String(localized: "`\(line)` did not start: \(error.localizedDescription)"))
        }
    }

    func read(_ path: String) async throws -> String? {
        var url = URL(fileURLWithPath: path, relativeTo: directory)
        if path.hasPrefix("~/"), let home { url = home.appending(path: String(path.dropFirst(2))) }
        url = url.standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return nil }
        let arguments = JSONValue.object(["path": .string(url.path)]).jsonString
        if let refusal = await gate.refusal(toolID: nil, name: "read_file", arguments: arguments) { throw CommandFailure(refusal) }
        do {
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        } catch {
            throw CommandFailure(String(localized: "\(path) could not be read: \(error.localizedDescription)"))
        }
    }
}
