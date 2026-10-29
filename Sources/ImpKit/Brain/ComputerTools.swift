import CoreGraphics
import Foundation

/// Names and schemas of the computer-control tools (the app runs them: `ComputerToolHost`), and what
/// their arguments mean. Off unless the Imp's "Computer control" group is on (`ImpToolGroup.computer`).
///
/// Coordinates the model sees and sends are *screenshot pixels*, origin at the window image's
/// top-left (see `ComputerSpace` for how they map to the screen).
public enum ComputerTools {
    public static let observe = "computer_observe"
    public static let act = "computer_act"
    public static let verify = "computer_verify"
    public static let all = [observe, act, verify]

    public static func isComputerTool(_ name: String) -> Bool { all.contains(name) }

    public static func specs() -> [ToolSpec] {
        let point: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                                "required": ["x", "y"]]
        return [
            ToolSpec(
                name: observe,
                description: "Look at an app on the Mac so you can operate it: a screenshot of its window plus a compact list of its "
                    + "accessible elements (id like e12, role, name, value, state, frame) and the app's other windows and menus. "
                    + "Defaults to the frontmost app's focused window. Coordinates are screenshot pixels from the window's top-left. "
                    + "If the app exposes few elements, work from the picture and click by coordinates. Always observe before acting, "
                    + "and again when the screen has changed a lot.",
                inputSchema: ["type": "object",
                              "properties": ["app": ["type": "string", "description": "App name or bundle id. Default: the frontmost app."],
                                             "window": ["type": "string", "description": "Part of a window's title, or its number in the window list. Default: the focused window."]]]),
            ToolSpec(
                name: act,
                description: "Operate the app you last observed (it's brought to the front first). `target` is an element id from the "
                    + "latest observation (e12) or text of its name; or give coordinates `x`,`y` (screenshot pixels) when there's no element. "
                    + "Prefers accessibility actions, falls back to real mouse and keyboard events. Returns what changed on screen "
                    + "(elements that appeared, disappeared or changed), not a picture: set `observe` to get a fresh screenshot too. "
                    + "Actions: \(ComputerAction.Kind.allCases.map(\.rawValue).joined(separator: ", ")). "
                    + "`type` types text (into `target` if given, else where the focus is); `set_value` sets an element's value directly; "
                    + "`key` presses a shortcut like \"cmd+shift+z\" or \"return\"; `scroll` uses `dx`,`dy` in pixels (dy > 0 scrolls down); "
                    + "`drag` goes from `target` (or the first `path` point) to `to`, or along `path`, a list of points, to draw a line or stroke; "
                    + "`select` chooses a popup/menu option by name (`target` the popup, `value` the option) or walks the menu bar with a path "
                    + "like \"File > Export > PNG\".",
                inputSchema: ["type": "object",
                              "properties": ["action": ["type": "string", "enum": .array(ComputerAction.Kind.allCases.map { .string($0.rawValue) })],
                                             "target": ["type": "string", "description": "Element id (e12) or the text of its name."],
                                             "x": ["type": "number", "description": "Window-relative x, screenshot pixels (when no target)."],
                                             "y": ["type": "number", "description": "Window-relative y, screenshot pixels (when no target)."],
                                             "value": ["type": "string", "description": "Text to type, value to set, shortcut for key, option or menu path for select."],
                                             "dx": ["type": "number"], "dy": ["type": "number"],
                                             "to": point,
                                             "path": ["type": "array", "items": point, "description": "Points to drag through (2 or more)."],
                                             "observe": ["type": "boolean", "description": "Also return a fresh screenshot."]],
                              "required": ["action"]]),
            ToolSpec(
                name: verify,
                description: "Check that something worked: looks at the app again and returns a screenshot and what changed since "
                    + "your last look, along with your `condition`. Judge it honestly: say whether the condition is met or not and why "
                    + "(from the picture, not from what you hoped), then fix it or report it.",
                inputSchema: ["type": "object",
                              "properties": ["condition": ["type": "string", "description": "What should be true now, e.g. \"the export dialog is open\"."]],
                              "required": ["condition"]]),
        ]
    }

    /// The model's wording for a missing permission (the tools return it as an error).
    public static func permissionError(screen: Bool, accessibility: Bool) -> String? {
        var missing: [String] = []
        if accessibility { missing.append("Accessibility (Device Control & Data Access)") }
        if screen { missing.append("Screen & System Audio Recording") }
        guard !missing.isEmpty else { return nil }
        return "Error: Imp doesn't have the permission \(missing.joined(separator: " and ")) yet, so it can't control the computer. "
            + "Ask the user to switch it on for Imp in System Settings › Privacy & Security (All Imps › Permissions in Imp has buttons for it), then try again."
    }
}

/// Where a `computer_act` points.
public enum ComputerTarget: Equatable, Sendable {
    /// An id from the latest observation ("e12").
    case element(String)
    /// Text of an element's name.
    case text(String)
    /// Screenshot pixels, window-relative.
    case point(CGPoint)

    /// From a tool argument: an id, text, "x,y", or an `{x, y}` object.
    public init?(_ json: JSONValue?) {
        guard let json else { return nil }
        if let point = ComputerAction.point(json) { self = .point(point); return }
        guard let raw = json.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.range(of: #"^e\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            self = .element(raw.lowercased())
        } else if let pair = Self.pair(raw) {
            self = .point(pair)
        } else {
            self = .text(raw)
        }
    }

    private static func pair(_ s: String) -> CGPoint? {
        let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// A validated `computer_act` request.
public struct ComputerAction: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case click, doubleClick = "double_click", rightClick = "right_click", press, focus, type
        case setValue = "set_value", key, scroll, drag, select, hover
    }

    public var kind: Kind
    public var target: ComputerTarget?
    /// Text to type, value to set, option to select (or menu path).
    public var value: String?
    public var keys: Hotkey?
    public var dx = 0.0
    public var dy = 0.0
    public var to: CGPoint?
    public var path: [CGPoint] = []
    public var observe = false

    /// "File > Export > PNG" for `select`, when that's what it asks for.
    public var menuPath: [String]? {
        guard kind == .select else { return nil }
        var candidate: String?
        if let value, value.contains(">"), target == nil { candidate = value }
        else if value == nil, case .text(let t)? = target, t.contains(">") { candidate = t }
        guard let candidate else { return nil }
        return candidate.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public init(arguments json: JSONValue) throws {
        let kindName = json["action"]?.string?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_") ?? ""
        guard let kind = Kind(rawValue: kindName) else {
            throw ToolArgumentError("`action` must be one of: \(Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self.kind = kind
        var target = ComputerTarget(json["target"])
        if target == nil, let x = json["x"]?.numberValue, let y = json["y"]?.numberValue { target = .point(CGPoint(x: x, y: y)) }
        self.target = target
        value = json["value"].flatMap { $0.string ?? $0.numberValue.map { String($0) } }
        dx = json["dx"]?.numberValue ?? 0
        dy = json["dy"]?.numberValue ?? 0
        if let to = json["to"] {
            guard let p = Self.point(to) else { throw ToolArgumentError("`to` must be {\"x\": number, \"y\": number}.") }
            self.to = p
        }
        if let raw = json["path"] {
            guard let list = raw.array else { throw ToolArgumentError("`path` must be a list of {\"x\", \"y\"} points.") }
            path = try list.map {
                guard let p = Self.point($0) else { throw ToolArgumentError("`path` must be a list of {\"x\", \"y\"} points.") }
                return p
            }
        }
        observe = json["observe"]?.bool ?? false
        try validate()
    }

    private mutating func validate() throws {
        func need(_ cond: Bool, _ message: String) throws { if !cond { throw ToolArgumentError(message) } }
        let name = kind.rawValue
        switch kind {
        case .click, .doubleClick, .rightClick, .press, .focus, .hover:
            try need(target != nil, "\(name) needs a `target` (element id or name text) or `x` and `y`.")
        case .type:
            try need(!(value ?? "").isEmpty, "type needs `value`: the text to type.")
        case .setValue:
            try need(target != nil, "set_value needs a `target` element.")
            try need(value != nil, "set_value needs `value`.")
        case .key:
            guard let value, !value.isEmpty else { throw ToolArgumentError("key needs `value`, a shortcut like \"cmd+shift+z\", \"return\" or \"escape\".") }
            guard let keys = Self.keyCombo(value) else {
                throw ToolArgumentError("I don't know the key “\(value)”. Write modifiers and one key joined by +: \"cmd+s\", \"ctrl+shift+tab\", \"return\", \"f5\".")
            }
            self.keys = keys
        case .scroll:
            try need(dx != 0 || dy != 0, "scroll needs `dx` and/or `dy` (pixels; dy > 0 scrolls down).")
        case .drag:
            try need(path.count >= 2 || (target != nil && (to != nil || !path.isEmpty)),
                     "drag needs a `target` to start from and `to` (or a `path`), or a `path` of 2 or more points.")
        case .select:
            if menuPath == nil {
                try need(target != nil && !(value ?? "").isEmpty, "select needs a `target` popup/menu with `value` the option name, or a menu path like \"File > Save As…\" in `value`.")
            } else {
                try need(menuPath?.isEmpty == false, "The menu path is empty.")
            }
        }
    }

    /// `{x, y}` as a point.
    static func point(_ json: JSONValue) -> CGPoint? {
        guard let x = json["x"]?.numberValue, let y = json["y"]?.numberValue else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A shortcut written out. Reuses `Hotkey(parsing:)`, plus a trailing "-" or "=" key ("cmd+-").
    public static func keyCombo(_ text: String) -> Hotkey? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 1, let last = t.last, "-=".contains(last), t.dropLast().last == "+",
           var combo = Hotkey(parsing: String(t.dropLast()) + "A"), let code = KeyNames.code(for: String(last)) {
            combo.keyCode = code
            return combo
        }
        return Hotkey(parsing: t)
    }
}

extension JSONValue {
    /// A number, or text that reads as one (models sometimes quote them).
    var numberValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
