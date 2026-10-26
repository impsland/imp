import Foundation

/// An Imp's one built-in tool: a shell on the user's Mac. Everything else (opening apps, files,
/// the clipboard, speaking, calling a service's image or speech API) the model does itself with
/// ordinary commands, so nothing about pictures or voices is wired into Imp.
public struct ShellTool: ToolProvider {
    public static let name = "shell"

    /// Where commands start (the Imp's own folder, see `Workspace`).
    public var directory: URL
    /// Extra environment for every command (`IMP_*`: who it is, its folder, its brain's endpoint).
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(directory: URL, environment: [String: String] = [:], timeout: TimeInterval = ShellRunner.defaultTimeout) {
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
    }

    /// The variables an Imp's commands get. The key is passed by name, never written into a prompt.
    public static func environment(name: String, directory: URL, baseURL: String?, apiKey: String?, model: String?) -> [String: String] {
        var env = ["IMP_NAME": name, "IMP_WORKSPACE": directory.path]
        if let baseURL, !baseURL.isEmpty { env["IMP_API_BASE_URL"] = baseURL }
        if let apiKey, !apiKey.isEmpty { env["IMP_API_KEY"] = apiKey }
        if let model, !model.isEmpty { env["IMP_MODEL"] = model }
        return env
    }

    public func tools() async -> [ToolSpec] {
        let api = environment["IMP_API_BASE_URL"] == nil ? "" : " $IMP_API_BASE_URL is your OpenAI-compatible API "
            + "(key in $IMP_API_KEY: use it in curl headers, never print it), for example for images or speech."
        return [ToolSpec(
            name: Self.name,
            description: "Run a zsh command on the user's Mac (macOS) and get its output and exit status. Use it for "
                + "anything beyond talking: open apps and URLs (`open -a`, `open`), read and write files, the clipboard "
                + "(`pbcopy`, `pbpaste`), speaking out loud (`say`), AppleScript (`osascript`), HTTP APIs (`curl`). "
                + "Commands start in your own folder ($IMP_WORKSPACE), which you may use for scripts and results. "
                + "Nothing is interactive: pass flags instead of waiting for input. Time limit: \(Int(timeout)) seconds." + api,
            inputSchema: [
                "type": "object",
                "properties": ["command": ["type": "string", "description": "The command line to run."]],
                "required": ["command"],
            ])]
    }

    public func call(_ name: String, arguments: String) async throws -> String {
        guard name == Self.name else { return "Error: unknown tool \(name)." }
        let command = (try? JSONValue(jsonString: arguments))?["command"]?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return "Error: give the command to run in `command`." }
        let r = try await ShellRunner.run(command, in: directory, environment: environment, timeout: timeout)
        return Self.report(r, timeout: timeout)
    }

    /// What the model reads back. Failures start with "Error:" so the bubble marks the step.
    static func report(_ r: ShellRunner.Result, timeout: TimeInterval) -> String {
        let output = r.output.isEmpty ? "(no output)" : r.output
        if r.timedOut { return "Error: stopped after \(Int(timeout)) seconds.\n\(output)" }
        return r.status == 0 ? output : "Error: exit status \(r.status).\n\(output)"
    }
}
