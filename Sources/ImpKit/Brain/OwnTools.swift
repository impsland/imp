import Foundation

/// An Imp's own tools, in groups that can be switched off one by one (Tools tab). They're
/// how the model acts out its answers, notices the Mac, sets itself up and talks to the troupe.
/// Nothing is hard-wired: a trigger hands the model what happened, and the model picks the tools.
public enum ImpToolGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Animations, moving around the screen, speaking out loud.
    case body
    /// The Mac's state (battery, processor, apps…) and the page open in the browser.
    case senses
    /// Its own triggers and extra tools (MCP servers): adding, listing, removing them.
    case setup
    /// Messages to the other Imps.
    case troupe
    /// Operating other apps through screenshots and accessibility (`ComputerTools`). Off until switched on.
    case computer

    /// Whether an Imp has the group before anyone chooses. Computer control is opt-in.
    public var isOnByDefault: Bool { self != .computer }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body: String(localized: "Body language")
        case .senses: String(localized: "Senses")
        case .setup: String(localized: "Setup")
        case .troupe: String(localized: "Other Imps")
        case .computer: String(localized: "Computer control")
        }
    }

    public var symbol: String {
        switch self {
        case .body: "figure.dance"
        case .senses: "sensor.fill"
        case .setup: "wand.and.stars"
        case .troupe: "person.3.fill"
        case .computer: "cursorarrow.click.2"
        }
    }

    public var summary: String {
        switch self {
        case .body: String(localized: "Plays animations, moves around the screen and speaks aloud.")
        case .senses: String(localized: "Reads the battery, processor, network and open apps. With the browser extension, it also knows the page you're on.")
        case .setup: String(localized: "Adds and removes its own triggers and extra tools when you ask.")
        case .troupe: String(localized: "Messages the other Imps on your desktop and hears their answers.")
        case .computer: String(localized: "Sees and operates other apps. Needs the Screen & System Audio Recording and Accessibility permissions.")
        }
    }
}

/// Names and schemas of an Imp's own tools (the app runs them, see `ImpTools`).
public enum OwnTools {
    public static let play = "imp_play_animations"
    public static let move = "imp_move"
    public static let speak = "imp_speak"
    public static let status = "mac_status"
    public static let page = "browser_page"
    public static let listTriggers = "imp_list_triggers"
    public static let addTrigger = "imp_add_trigger"
    public static let removeTrigger = "imp_remove_trigger"
    public static let listTools = "imp_list_tools"
    public static let addTool = "imp_add_tool"
    public static let removeTool = "imp_remove_tool"
    public static let openSettings = "imp_open_settings"
    public static let message = "imp_message"
    public static let makeAnimation = "imp_make_animation"
    public static let showAnimation = "imp_show_animation"
    public static let removeAnimation = "imp_remove_animation"
    public static let setTraits = "imp_set_traits"

    /// Which group a tool belongs to.
    public static func group(of tool: String) -> ImpToolGroup? {
        switch tool {
        case play, move, speak, makeAnimation, showAnimation, removeAnimation, setTraits: .body
        case status, page: .senses
        case listTriggers, addTrigger, removeTrigger, listTools, addTool, removeTool, openSettings: .setup
        case message: .troupe
        case ComputerTools.observe, ComputerTools.act, ComputerTools.verify: .computer
        default: nil
        }
    }

    /// Making and changing animations, and its own character.
    static func animatorSpecs(_ animations: [String]) -> [ToolSpec] {
        let beat: JSONValue = [
            "type": "object",
            "properties": [
                "duration": ["type": "number", "description": "Seconds to hold this beat (0.05–6)."],
                "look": ["type": "array", "items": ["type": "number"],
                         "description": "Where your face turns: [x, y], each −1…1 (x right +, y down +; [0, 0.1] is at the user). Leave out to follow the cursor or the mood."],
                "mood": ["type": "string", "enum": .array(AnimationBeat.moods.map { .string($0) })],
                "glyph": ["type": "string", "enum": .array(AnimationBeat.glyphs.map { .string($0) }), "description": "A little symbol above your head."],
                "tilt": ["type": "number", "description": "Head tilt in degrees (−30…30, + leans right)."],
                "hop": ["type": "boolean", "description": "Hop as this beat starts (a hop takes 0.75 s)."],
                "stretch": ["type": "number", "description": "Body shape: + tall and thin, − squished flat (−0.3…0.3)."],
            ],
            "required": ["duration"],
        ]
        let starts = JSONValue.array(AnimationTrigger.allCases.map { .string($0.rawValue) })
        return [
            ToolSpec(
                name: makeAnimation,
                description: "Make a new animation, or change one: a sequence of beats (poses held for a while), like the ones you play. "
                    + "Give a new `name` for a new one, the name of one you made to change it, or `replaces` with a built-in animation's id "
                    + "to make your own version of it (it then plays instead of the built-in one). Look at an existing one first with "
                    + "\(showAnimation) to get the feel. It's yours alone unless `for` is `everyone`. It plays once when saved.",
                inputSchema: ["type": "object",
                              "properties": [
                                "name": ["type": "string", "description": "Short, like the built-in ones (≤ 40 characters)."],
                                "about": ["type": "string", "description": "What it looks like, in a few words."],
                                "replaces": ["type": "string", "enum": .array(Reaction.allCases.map { .string($0.rawValue) })],
                                "beats": ["type": "array", "items": beat, "description": "1–24 beats, at most 20 s in all."],
                                "starts": ["type": "array", "items": ["type": "string", "enum": starts],
                                           "description": "What starts it on its own (idle: in quiet moments; the rest are things the user does with the cursor or to you). Not for replacements."],
                                "for": ["type": "string", "enum": ["me", "everyone"], "description": "Just you (default), or every Imp."],
                              ],
                              "required": ["beats"]]),
            ToolSpec(
                name: showAnimation,
                description: "The beats of an animation (built-in or made), as \(makeAnimation) takes them. Without `name`, lists the animations that were made, and your character traits.",
                inputSchema: ["type": "object", "properties": ["name": ["type": "string"]]]),
            ToolSpec(
                name: removeAnimation,
                description: "Remove an animation that was made (a replaced built-in one plays again).",
                inputSchema: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]),
            ToolSpec(
                name: setTraits,
                description: "Set your character: how your eyes, brows and horns always look, in every mood and animation and while you "
                    + "follow the cursor, and how fast you act. Start from a `preset` and/or set values; anything left out stays as it is.",
                inputSchema: ["type": "object",
                              "properties": [
                                "preset": ["type": "string", "enum": .array(ImpTraits.presets.map { .string($0.id) })],
                                "lids": ["type": "number", "description": "Heavy, tired lids: 0…0.6."],
                                "slant": ["type": "number", "description": "Brows: −1 worried … +1 cross."],
                                "eyes": ["type": "number", "description": "Eye size: −0.4…0.4."],
                                "squint": ["type": "number", "description": "One eye narrower: −1…1."],
                                "horns": ["type": "number", "description": "Degrees: −30 droopy … +30 perky."],
                                "blush": ["type": "number", "description": "Rosy cheeks: 0…1."],
                                "tilt": ["type": "number", "description": "Head cocked, degrees: −12…12."],
                                "tempo": ["type": "number", "description": "How fast you act: 0.6 slow … 1.6 quick."],
                              ]]),
        ]
    }

    /// Ways to get somewhere on screen.
    public static let moveStyles = ["hop", "slide", "bounce", "jump"]
    /// Named places on screen.
    public static let places = ["home", "cursor", "center", "left", "right", "top", "bottom",
                                "top-left", "top-right", "bottom-left", "bottom-right"]

    /// The tools for `groups`. `animations`: names it may play right now; `imps`: the others it can message.
    public static func specs(_ groups: Set<ImpToolGroup>, animations: [String], imps: [String], browser: Bool,
                             talk: ImpTalk = .own) -> [ToolSpec] {
        var specs: [ToolSpec] = []
        if groups.contains(.body) {
            specs.append(ToolSpec(
                name: play,
                description: "Act something out with your body: play one or more of your animations, one after another "
                    + "(body language for what you say, or a reaction). They play once your reply shows; animations from several calls "
                    + "all play, in the order you asked for them. Use them often "
                    + "and naturally, like a lively little creature, but not for every message.",
                inputSchema: ["type": "object",
                              "properties": ["names": ["type": "array", "items": ["type": "string", "enum": .array(animations.map { .string($0) })],
                                                       "description": "Animations, in order (1–4)."]],
                              "required": ["names"]]))
            var targets = "Where to go: a named place (\(places.joined(separator: ", "))), or x/y as fractions of the screen "
                + "(0…1, from its top-left corner)."
            if browser { targets += " Or `element`: text on a button or link in the browser's active tab, to sit right on top of it." }
            specs.append(ToolSpec(
                name: move,
                description: "Move yourself (the little character on the user's desktop) somewhere on screen. " + targets
                    + " `home` goes back to where the user put you.",
                inputSchema: ["type": "object",
                              "properties": ["to": ["type": "string", "enum": .array(places.map { .string($0) })],
                                             "x": ["type": "number"], "y": ["type": "number"],
                                             "element": ["type": "string", "description": "Visible text (or a CSS selector) of an element in the browser page."],
                                             "style": ["type": "string", "enum": .array(moveStyles.map { .string($0) }),
                                                       "description": "hop: one leap; slide: glide; bounce: a few bounces like a ball; jump: a big, quick leap."]]]))
            specs.append(contentsOf: animatorSpecs(animations))
            specs.append(ToolSpec(
                name: speak,
                description: "Say something out loud with the Mac's voice (your reply still shows in the bubble). Keep it short.",
                inputSchema: ["type": "object",
                              "properties": ["text": ["type": "string"],
                                             "language": ["type": "string", "description": "BCP-47 code, e.g. en-US, zh-CN. Default: the text's own."]],
                              "required": ["text"]]))
        }
        if groups.contains(.senses) {
            specs.append(ToolSpec(
                name: status,
                description: "How the Mac is right now: battery and charger, processor load, heat, memory, network, the app "
                    + "in front and the apps that are open, time away from the keyboard, the time, the screen, and the page in the browser.",
                inputSchema: ["type": "object", "properties": [:]]))
            if browser {
                specs.append(ToolSpec(
                    name: page,
                    description: "The page in the browser's active tab: its address and title, and with `read` its visible text.",
                    inputSchema: ["type": "object", "properties": ["read": ["type": "boolean"]]]))
            }
        }
        if groups.contains(.setup) {
            specs.append(ToolSpec(
                name: listTriggers,
                description: "Your triggers: what sets you off (keys, clicks on you, or something on the Mac) and what you do then.",
                inputSchema: ["type": "object", "properties": [:]]))
            specs.append(ToolSpec(
                name: addTrigger,
                description: "Create (or, with `id`, change) a trigger the user asks for: when something happens, you get the "
                    + "`prompt` along with what happened, and respond with your tools (animations, moving, speech, shell…). "
                    + "Events (`when.kind`): keys (`when.keys`, e.g. \"ctrl+cmd+T\"), clicks (number 1–3 on you), battery "
                    + "(below number %), charger (flag: plugged in true/unplugged false), app (text: app name comes to the "
                    + "front), website (text: part of the address, needs the browser extension), time (text \"HH:MM\" daily), "
                    + "every (number minutes), back (user back after number minutes away), wake, start, busy (processor above "
                    + "number %), hot, offline (flag: goes offline true / back online false). `only_if`: conditions that must "
                    + "hold too, same shape (battery, charger, app, website, busy, hot, offline, or hours with text \"22:00-07:00\"). "
                    + "`do` is ask (default: you get the prompt) or opens something: type (text box), talk (listen), chat, settings. "
                    + "Afterwards tell the user how to use it.",
                inputSchema: ["type": "object",
                              "properties": [
                                "id": ["type": "string", "description": "An existing trigger's id, to change it."],
                                "name": ["type": "string", "description": "A short name."],
                                "when": condition(events: true),
                                "only_if": ["type": "array", "items": condition(events: false)],
                                "do": ["type": "string", "enum": .array(Shortcut.Command.allCases.map { .string($0.rawValue) })],
                                "prompt": ["type": "string", "description": "What you should do when it goes off, in plain words to yourself."],
                                "with_clipboard": ["type": "boolean", "description": "Hand over what the user copied (text or a picture)."],
                                "every_imp": ["type": "boolean", "description": "For every Imp instead of just you."],
                              ],
                              "required": ["when"]]))
            specs.append(ToolSpec(
                name: removeTrigger,
                description: "Remove one of your triggers (by id, from imp_list_triggers) when the user asks.",
                inputSchema: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]))
            specs.append(ToolSpec(
                name: listTools,
                description: "The extra tools (MCP servers) in the library, whether you use each, and whether it's running.",
                inputSchema: ["type": "object", "properties": [:]]))
            specs.append(ToolSpec(
                name: addTool,
                description: "Add an extra tool (an MCP server) and start using it, when the user asks for something you "
                    + "can't do yet and a server can. Local: `command` is the whole command line (e.g. \"npx -y @scope/server\"), "
                    + "with `env`. Remote: `url`, with `headers`. Leave secrets empty (\"\"): then open its settings "
                    + "(imp_open_settings with page tools and the tool's id) and ask the user to fill them in. Its tools are "
                    + "yours from the next message on.",
                inputSchema: ["type": "object",
                              "properties": ["name": ["type": "string"], "command": ["type": "string"], "url": ["type": "string"],
                                             "env": ["type": "object", "additionalProperties": ["type": "string"]],
                                             "headers": ["type": "object", "additionalProperties": ["type": "string"]]]]))
            specs.append(ToolSpec(
                name: removeTool,
                description: "Stop using an extra tool (by id). With `everywhere`, remove it from the library for every Imp.",
                inputSchema: ["type": "object", "properties": ["id": ["type": "string"], "everywhere": ["type": "boolean"]],
                              "required": ["id"]]))
            specs.append(ToolSpec(
                name: openSettings,
                description: "Open your settings on a page for the user: looks, brain, tools (with `tool`: an extra tool's id, "
                    + "to edit it, e.g. to fill in an API key) or triggers.",
                inputSchema: ["type": "object",
                              "properties": ["page": ["type": "string", "enum": ["looks", "brain", "tools", "triggers"]],
                                             "tool": ["type": "string"]],
                              "required": ["page"]]))
        }
        if groups.contains(.troupe), !imps.isEmpty {
            var properties: [String: JSONValue] = ["to": ["type": "string", "enum": .array(imps.map { .string($0) })],
                                                   "text": ["type": "string"]]
            if talk == .decides {
                let where_ = "Where the two of you talk: `own` (default) is a private chat between you and that Imp, "
                    + "kept apart from the user's; `shared` is the chat that Imp has with the user (use it when the user "
                    + "should see or take part in what's said)."
                properties["chat"] = ["type": "string", "enum": ["own", "shared"], "description": .string(where_)]
            }
            specs.append(ToolSpec(
                name: message,
                description: "Send a message to another Imp out on the desktop and get its answer (it shows its own bubble). "
                    + "Keep it short and friendly.",
                inputSchema: ["type": "object", "properties": .object(properties), "required": ["to", "text"]]))
        }
        return specs
    }

    private static func condition(events: Bool) -> JSONValue {
        let kinds = Trigger.Kind.allCases.filter { events ? $0.isEvent : $0.isCondition }
        var properties: [String: JSONValue] = [
            "kind": ["type": "string", "enum": .array(kinds.map { .string($0.rawValue) })],
            "number": ["type": "integer"], "text": ["type": "string"], "flag": ["type": "boolean"],
        ]
        if events { properties["keys"] = ["type": "string", "description": "For kind keys: e.g. \"ctrl+cmd+T\"."] }
        return ["type": "object", "properties": .object(properties), "required": ["kind"]]
    }
}

/// A tool's arguments that don't make sense, in words the model can fix.
public struct ToolArgumentError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension Trigger {
    /// From a tool's `when` / `only_if` object (see `OwnTools.addTrigger`).
    public init(tool json: JSONValue, asCondition: Bool = false) throws {
        guard let raw = json["kind"]?.string, let kind = Kind(rawValue: raw.lowercased()) else {
            throw ToolArgumentError("Unknown trigger kind \(json["kind"]?.jsonString ?? "(none)").")
        }
        if asCondition && !kind.isCondition { throw ToolArgumentError("\(raw) can't be a condition (only_if).") }
        if !asCondition && !kind.isEvent { throw ToolArgumentError("\(raw) only works as a condition (only_if).") }
        self = .starter(kind)
        let number = json["number"]?.int ?? (json["number"]?.string).flatMap { Int($0) }
        let text = json["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .clicks, .battery, .every, .back, .busy:
            if let number { self.number = number }
            if kind == .clicks, let n = number, !(1...Self.maxClicks).contains(n) {
                throw ToolArgumentError("Clicks go from 1 to \(Self.maxClicks).")
            }
        case .charger, .offline:
            if let flag = json["flag"]?.bool { self.flag = flag }
        case .app, .website:
            self.text = text ?? ""
        case .time:
            guard let m = text.flatMap(Self.minuteOfDay(parsing:)) ?? number else { throw ToolArgumentError("Give the time as text \"HH:MM\".") }
            self.number = m
        case .hours:
            let parts = (text ?? "").split(separator: "-").map { Self.minuteOfDay(parsing: String($0)) }
            guard parts.count == 2, let a = parts[0], let b = parts[1] else { throw ToolArgumentError("Give hours as text \"22:00-07:00\".") }
            self.number = a; self.until = b
        case .keys, .wake, .start, .hot:
            break
        }
    }
}

extension Shortcut {
    /// A trigger from `imp_add_trigger`'s arguments, for `imp` (or every Imp), keeping the id of
    /// the one it changes.
    public init(tool json: JSONValue, imp: UUID, replacing old: Shortcut? = nil) throws {
        guard let when = json["when"] else { throw ToolArgumentError("Say when it goes off (`when`).") }
        let trigger = try Trigger(tool: when)
        let conditions = try (json["only_if"]?.array ?? []).map { try Trigger(tool: $0, asCondition: true) }
        let doing = json["do"]?.string.map { $0.lowercased() } ?? "ask"
        guard let command = Command(rawValue: doing) else { throw ToolArgumentError("Unknown `do`: \(doing).") }
        let prompt = json["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? old?.prompt ?? ""
        var hotkey: Hotkey?
        if trigger.kind == .keys {
            guard let text = when["keys"]?.string, let keys = Hotkey(parsing: text) else {
                throw ToolArgumentError("Give the keys in `when.keys`, like \"ctrl+cmd+T\".")
            }
            guard keys.isValidGlobalShortcut else { throw ToolArgumentError("\(keys.displayString) needs ⌘, ⌥ or ⌃ (or a function key).") }
            hotkey = keys
        }
        let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whose it is: as asked, else whose it was, else this Imp's.
        let performer: UUID? = if let every = json["every_imp"]?.bool { every ? nil : imp } else if let old { old.performer } else { imp }
        self.init(name: name?.isEmpty == false ? name! : (old?.name ?? trigger.summary), hotkey: hotkey, prompt: prompt,
                  performer: performer,
                  usesClipboard: json["with_clipboard"]?.bool ?? false, trigger: trigger, conditions: conditions, command: command)
        if let old { id = old.id; isEnabled = old.isEnabled }
        guard isRunnable else { throw ToolArgumentError("Give it a `prompt` (or `do` something, or hand over the clipboard).") }
    }

    /// One line for the model: id, name, when, what.
    public var toolDescription: String {
        var line = "\(id.uuidString): “\(name)”: \(triggerSummary)"
        line += command == .ask ? " → ask: \(prompt.isEmpty ? "(respond to it)" : prompt)" : " → \(command.title.lowercased())"
        if usesClipboard { line += " (with the clipboard)" }
        if performer == nil { line += " [every Imp]" }
        if !isEnabled { line += " [off]" }
        return line
    }
}

extension MCPServerConfig {
    /// A server from `imp_add_tool`'s arguments.
    public init(tool json: JSONValue) throws {
        let strings = { (key: String) -> [String: String] in
            (json[key].flatMap { v -> [String: JSONValue]? in if case .object(let o) = v { return o } else { return nil } } ?? [:])
                .compactMapValues { $0.string ?? $0.int.map(String.init) }
        }
        let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = json["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
                throw ToolArgumentError("`url` must be an http(s) address.")
            }
            self.init(name: name.isEmpty ? Self.suggestedName(url: url) : name, transport: .http, url: url, headers: strings("headers"))
            return
        }
        guard let line = json["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            throw ToolArgumentError("Give a `command` (local server) or a `url` (remote one).")
        }
        self.init(name: name, transport: .stdio, environment: strings("env"))
        commandLine = line
        guard !command.isEmpty else { throw ToolArgumentError("`command` is empty.") }
        if self.name.isEmpty { self.name = Self.suggestedName(commandLine: arguments + [command]) }
    }

    /// Settings it still needs from the user: environment variables or headers left empty, or
    /// still holding a placeholder like "sk-..." or "<your key>".
    public var missingSecrets: [String] {
        func missing(_ v: String) -> Bool {
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasSuffix("...") || t.hasSuffix("…") || (t.hasPrefix("<") && t.hasSuffix(">"))
                || t.uppercased().contains("YOUR_") || t.lowercased().contains("your key")
        }
        return (Array(environment.filter { missing($0.value) }.keys) + Array(headers.filter { missing($0.value) }.keys)).sorted()
    }
}
