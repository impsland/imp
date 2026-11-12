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
            return args["app"]?.string.map { String(localized: "Looking at \(clip($0))") } ?? String(localized: "Looking at the screen")
        case ComputerTools.verify:
            return args["condition"]?.string.map { String(localized: "Checking: \(clip($0))") } ?? String(localized: "Checking the result")
        default:
            let action = args["action"]?.string ?? ""
            let target = args["target"]?.string.map(clip)
            let value = args["value"]?.string.map(clip)
            switch action {
            case "click":
                return target.map { String(localized: "Clicking “\($0)”") } ?? String(localized: "Clicking")
            case "double_click":
                return target.map { String(localized: "Double-clicking “\($0)”") } ?? String(localized: "Double-clicking")
            case "right_click":
                return target.map { String(localized: "Right-clicking “\($0)”") } ?? String(localized: "Right-clicking")
            case "press":
                return target.map { String(localized: "Pressing “\($0)”") } ?? String(localized: "Pressing")
            case "focus":
                return target.map { String(localized: "Focusing “\($0)”") } ?? String(localized: "Focusing")
            case "type":
                return target.map { String(localized: "Typing in “\($0)”") } ?? String(localized: "Typing")
            case "set_value":
                return target.map { String(localized: "Setting “\($0)”") } ?? String(localized: "Setting")
            case "key":
                return value.map { String(localized: "Pressing keys \($0)") } ?? String(localized: "Pressing keys")
            case "scroll":
                return target.map { String(localized: "Scrolling “\($0)”") } ?? String(localized: "Scrolling")
            case "drag":
                return target.map { String(localized: "Dragging “\($0)”") } ?? String(localized: "Dragging")
            case "select":
                return value.map { String(localized: "Choosing \($0)") } ?? target.map { String(localized: "Choosing “\($0)”") } ?? String(localized: "Choosing")
            case "hover":
                return target.map { String(localized: "Pointing at “\($0)”") } ?? String(localized: "Pointing at")
            default:
                return String(localized: "Operating the computer")
            }
        }
    }

    /// The first line of a command, short enough for a step row.
    public static func commandLine(_ command: String, limit: Int = 60) -> String {
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !first.isEmpty else { return String(localized: "Running a command") }
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
