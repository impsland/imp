import Foundation

/// How a tool call reads in an Imp's bubble while it runs: "open -a Safari", "Files › read file".
public struct ToolLabel: Equatable, Sendable {
    public var title: String
    /// An SF Symbol.
    public var icon: String
    /// The whole request, for reading in full: a command as typed, other tools' arguments as indented JSON.
    public var request: String

    public init(tool: String, arguments: String) {
        if tool == ShellTool.name {
            let command = (try? JSONValue(jsonString: arguments))?["command"]?.string ?? ""
            (title, icon, request) = (Self.commandLine(command), "terminal", command.isEmpty ? arguments : command)
        } else if ComputerTools.isComputerTool(tool) {
            (title, icon, request) = (Self.computerTitle(tool, arguments), "cursorarrow.click.2", Self.indented(arguments))
        } else {
            (title, icon, request) = (Self.displayName(tool), "hammer", Self.indented(arguments))
        }
    }

    /// "Looking at Safari", "Clicking “Save”", "Typing", "Checking: the dialog is open".
    static func computerTitle(_ tool: String, _ arguments: String) -> String {
        let args = (try? JSONValue(jsonString: arguments)) ?? [:]
        func clip(_ s: String) -> String { s.count > 40 ? String(s.prefix(40)) + "…" : s }
        switch tool {
        case ComputerTools.observe:
            return args["app"]?.string.map { "Looking at \(clip($0))" } ?? "Looking at the screen"
        case ComputerTools.verify:
            return args["condition"]?.string.map { "Checking: \(clip($0))" } ?? "Checking the result"
        default:
            let action = args["action"]?.string ?? ""
            let what = args["target"]?.string.map { " “\(clip($0))”" } ?? ""
            let verb: [String: String] = ["click": "Clicking", "double_click": "Double-clicking", "right_click": "Right-clicking",
                                          "press": "Pressing", "focus": "Focusing", "type": "Typing", "set_value": "Setting",
                                          "key": "Pressing keys", "scroll": "Scrolling", "drag": "Dragging", "select": "Choosing",
                                          "hover": "Pointing at"]
            guard let v = verb[action] else { return "Operating the computer" }
            if action == "key" || action == "select", let value = args["value"]?.string { return "\(v) \(clip(value))" }
            return v + what
        }
    }

    /// The first line of a command, short enough for a step row.
    public static func commandLine(_ command: String, limit: Int = 60) -> String {
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !first.isEmpty else { return "Running a command" }
        let more = first.count > limit || command.contains("\n")
        return String(first.prefix(limit)) + (more ? "…" : "")
    }

    /// JSON, indented for reading (or as it came, if it isn't JSON).
    static func indented(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    /// `files__read_file` → `Files › read file`, for showing MCP tool names to people.
    public static func displayName(_ tool: String) -> String {
        let pretty = tool.components(separatedBy: "__").map { $0.replacingOccurrences(of: "_", with: " ") }
        guard let first = pretty.first, !first.isEmpty else { return tool }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + pretty.dropFirst()).joined(separator: " › ")
    }
}
