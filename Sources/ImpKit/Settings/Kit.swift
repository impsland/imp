import Foundation

/// A kit: Imps, triggers and borrowed tools (MCP servers) packaged as one piece of JSON, to share and
/// to add without clicking through Settings. Also the file format for exporting and importing Imps
/// (a backup, a move to another Mac, "my Imp" sent to a friend).
///
///     { "imp": 2, "app": "1.7.0", "name": "Morning helper", "about": "optional text",
///       "imps": [ { …an Imp, see `KitImp`… } ],
///       "triggers": [ { …the arguments of imp_add_trigger… } ],
///       "mcpServers": { "name": { "command": …, "args": […], "env": {…} } or { "url": …, "headers": {…} } },
///       "animations": [ { …an animation, see `MadeAnimation(kit:)`… } ] }
///
/// Parsing reuses the parsers behind the Imp's own tools (`Shortcut(tool:imp:)`, `MCPServerConfig.parse(setup:)`),
/// and also takes what people paste without the wrapper: a plain MCP snippet, or a trigger (or a list of them).
/// Nothing in a kit is applied by parsing it: the app shows it for review first.
///
/// ## Versions
/// `"imp"` is the format version, and it means the *minimum reader version* that understands the kit.
/// - Writers emit the lowest version that can express what's in the kit (`formatVersion`): triggers and
///   tools only is 1, so an Imp that only reads version 1 still opens it; a kit with Imps is 2; a kit with
///   animations (or Imps with their own animations or traits) is 3, since an older Imp would leave them out.
/// - A reader takes every version up to `currentVersion` and refuses a higher one with
///   `KitError.newerVersion` ("update Imp"), rather than half-reading it.
/// - Adding a field, or an optional section, is not a new version: readers ignore keys they don't know,
///   and a missing one takes its default. Only a change older readers would misread (a field that means
///   something else, a required one) bumps `currentVersion`; `migrate(_:from:)` then upgrades what older
///   versions wrote, as JSON, before it's read, so the reader only ever deals with the newest shape.
/// - `"app"` is the version of Imp that wrote the file. Informational: nothing reads it.
public struct Kit: Equatable, Sendable {
    public static let currentVersion = 3
    /// The biggest kit from a web address, a link or pasted text.
    public static let maxBytes = 512 * 1024
    /// The biggest kit file on this Mac: chats can make an exported Imp big.
    public static let maxFileBytes = 20 * 1024 * 1024
    public static let maxImps = 20
    public static let maxChatsPerImp = 100
    public static let maxTriggers = 50
    public static let maxServers = 20
    /// Animations in a kit, its own and its Imps' together.
    public static let maxAnimations = 50

    public var name: String
    public var about: String
    public var triggers: [Shortcut]
    public var servers: [MCPServerConfig]
    public var imps: [KitImp]
    /// Animations for whoever adds the kit (an Imp's own come with it, in `KitImp.animations`).
    public var animations: [MadeAnimation]
    /// The version of Imp that wrote the kit: read from a file, written when it's set (the app passes it in).
    public var app: String?
    /// Items that couldn't be read ("Trigger 2: Unknown trigger kind …"). The rest of the kit still stands.
    public var problems: [String]

    public init(name: String = "", about: String = "", triggers: [Shortcut] = [], servers: [MCPServerConfig] = [],
                imps: [KitImp] = [], animations: [MadeAnimation] = [], app: String? = nil, problems: [String] = []) {
        self.name = name; self.about = about; self.triggers = triggers; self.servers = servers; self.imps = imps
        self.animations = animations
        self.app = app; self.problems = problems
    }

    public var itemCount: Int { triggers.count + servers.count + imps.count + animations.count }

    /// The version this kit is written as: the lowest that can express it (see Versions above).
    public var formatVersion: Int {
        if !animations.isEmpty || imps.contains(where: { !$0.animations.isEmpty || !$0.traits.isPlain }) { return 3 }
        return imps.isEmpty ? 1 : 2
    }

    /// Servers no Imp of the kit uses (the ones the review lists on their own).
    public var looseServers: [MCPServerConfig] {
        let used = Set(imps.flatMap(\.servers))
        return servers.filter { !used.contains($0.id) }
    }

    /// Upgrades a kit written in an older format to the current one, before it's read. Version 2 only
    /// added `imps` and 3 `animations` and `traits`, so there's nothing to rewrite yet. A future breaking change adds its step here,
    /// one version at a time (`if version < 3 { … }`).
    static func migrate(_ json: JSONValue, from version: Int) -> JSONValue {
        json
    }

    // MARK: Reading

    /// A kit from pasted or downloaded text. Throws when the text isn't a kit at all; items that
    /// are bad end up in `problems` instead.
    public static func parse(_ text: String, limit: Int = maxBytes) throws -> Kit {
        guard text.utf8.count <= limit else { throw KitError.tooLarge }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KitError.empty }
        var kit: Kit
        if trimmed.first == "[" {
            guard let list = (try? JSONValue(jsonString: trimmed))?.array else { throw KitError.notAKit }
            kit = Kit()
            kit.read(triggers: list)
        } else if trimmed.first == "{", let json = try? JSONValue(jsonString: trimmed) {
            if json["imp"] != nil || json["triggers"] != nil || json["imps"] != nil || json["animations"] != nil {
                kit = try envelope(json)
            } else if json["when"] != nil {
                kit = Kit()
                kit.read(triggers: [json])
            } else {
                kit = try snippet(trimmed)
            }
        } else {
            kit = try snippet(trimmed)
        }
        guard kit.triggers.count <= maxTriggers else { throw KitError.tooMany("triggers", maxTriggers) }
        guard kit.servers.count <= maxServers else { throw KitError.tooMany("tools", maxServers) }
        guard kit.imps.count <= maxImps else { throw KitError.tooMany("Imps", maxImps) }
        guard kit.imps.allSatisfy({ $0.chats.count <= maxChatsPerImp }) else { throw KitError.tooMany("chats", maxChatsPerImp) }
        guard kit.animations.count + kit.imps.reduce(0, { $0 + $1.animations.count }) <= maxAnimations else {
            throw KitError.tooMany("animations", maxAnimations)
        }
        guard kit.itemCount > 0 else {
            throw kit.problems.isEmpty ? KitError.empty : KitError.nothingUsable(kit.problems)
        }
        return kit
    }

    private static func envelope(_ original: JSONValue) throws -> Kit {
        var json = original
        if let version = json["imp"] {
            guard let v = version.int, v >= 1 else { throw KitError.notAKit }
            guard v <= currentVersion else { throw KitError.newerVersion(v) }
            json = migrate(json, from: v)
        }
        var kit = Kit(name: json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                      about: json["about"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                      app: json["app"]?.string)
        if let list = json["triggers"] {
            if let array = list.array { kit.read(triggers: array) } else { kit.problems.append(String(localized: "“triggers” should be a list.")) }
        }
        if let map = json["mcpServers"] {
            if case .object(let entries) = map { kit.read(servers: entries) } else { kit.problems.append(String(localized: "“mcpServers” should be an object.")) }
        }
        if let list = json["imps"] {
            if let array = list.array { kit.read(imps: array) } else { kit.problems.append(String(localized: "“imps” should be a list.")) }
        }
        if let list = json["animations"] {
            if let array = list.array {
                kit.animations = MadeAnimation.read(array, problems: &kit.problems)
            } else {
                kit.problems.append(String(localized: "“animations” should be a list."))
            }
        }
        return kit
    }

    /// Whatever `MCPServerConfig.parse(setup:)` takes: a config, a command line, an address.
    private static func snippet(_ text: String) throws -> Kit {
        let servers = MCPServerConfig.parse(setup: text)
        guard !servers.isEmpty else { throw KitError.notAKit }
        return Kit(servers: servers)
    }

    private mutating func read(triggers list: [JSONValue]) {
        for (i, item) in list.enumerated() {
            do {
                var shortcut = try Shortcut(tool: item, imp: UUID())
                shortcut.performer = nil          // whose it is gets decided when it's added
                triggers.append(shortcut)
            } catch {
                let label = item["name"]?.string.map { String(localized: "Trigger \(i + 1) (“\($0)”)") } ?? String(localized: "Trigger \(i + 1)")
                problems.append("\(label): \(Self.message(error))")
            }
        }
    }

    private mutating func read(imps list: [JSONValue]) {
        let names = Dictionary(servers.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        for (i, item) in list.enumerated() {
            var problems: [String] = []
            let label = item["name"]?.string.map { String(localized: "Imp \(i + 1) (“\($0)”)") } ?? String(localized: "Imp \(i + 1)")
            if let imp = KitImp.read(item, servers: names, problems: &problems) { imps.append(imp) }
            self.problems += problems.map { "\(label): \($0)" }
        }
    }

    private mutating func read(servers entries: [String: JSONValue]) {
        for key in entries.keys.sorted() {
            // One entry at a time, through the same parser the Tools tab's Paste uses; a server
            // named like a wrapper key ("mcp") is no trouble that way.
            guard case .object = entries[key]!, var server = MCPServerConfig.parse(setup: entries[key]!.jsonString).first else {
                problems.append(String(localized: "Tool “\(key)”: needs a `command` (a program) or a `url` (a web address)."))
                continue
            }
            server.name = key
            servers.append(server)
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Warnings

    /// What to know before adding: code that would run on this Mac, keys to fill in, keys already taken.
    /// `services`: the ones the user has, to tell whether an Imp's brain can be matched (nil: don't say).
    public func warnings(existing: [Shortcut] = [], services: [Service]? = nil) -> [KitWarning] {
        var out: [KitWarning] = []
        for imp in imps {
            if let b = imp.brain, let address = b.baseURL, let services,
               !services.contains(where: { AIConfig.normalized($0.baseURL) == AIConfig.normalized(address) }) {
                let what = b.summary.isEmpty ? String(localized: "another service") : b.summary
                out.append(KitWarning(kind: .brainMissing, item: imp.id,
                                      text: String(localized: "Uses \(what), which you haven't added: it will use your default until you set one")))
            }
            if imp.uses(.computer) {
                out.append(KitWarning(kind: .computerControl, item: imp.id,
                                      text: String(localized: "Can control your Mac: it takes screenshots and clicks and types in other apps")))
            }
        }
        for server in servers {
            if server.transport == .stdio {
                out.append(KitWarning(kind: .runsCommand, item: server.id, text: String(localized: "“\(server.name)” runs a command on your Mac: \(server.commandLine)")))
            }
            if !server.missingSecrets.isEmpty {
                out.append(KitWarning(kind: .needsSecrets, item: server.id,
                                      text: String(localized: "“\(server.name)” needs you to fill in: \(server.missingSecrets.joined(separator: ", "))")))
            }
        }
        var taken: [Hotkey: String] = [:]
        for s in existing { if let keys = s.keys { taken[keys] = "“\(s.displayLabel)”" } }
        for s in triggers + imps.flatMap(\.triggers) {
            guard let keys = s.keys else { continue }
            if let other = taken[keys] {
                out.append(KitWarning(kind: .keysInUse, item: s.id, text: String(localized: "\(keys.displayString) is already used by \(other)")))
            }
            taken[keys] = String(localized: "another trigger in this kit")
        }
        return out
    }

    // MARK: Writing

    /// The kit as JSON text: readable, or compact for a link. Secrets are never in it (`KitExport`).
    public func json(pretty: Bool = true) -> String {
        var top: [String: JSONValue] = ["imp": .number(Double(formatVersion))]
        if let app, !app.isEmpty { top["app"] = .string(app) }
        if !name.isEmpty { top["name"] = .string(name) }
        if !about.isEmpty { top["about"] = .string(about) }
        let keys = serverKeys
        if !imps.isEmpty { top["imps"] = .array(imps.map { $0.kitJSON(serverKeys: keys) }) }
        if !triggers.isEmpty { top["triggers"] = .array(triggers.map(\.kitJSON)) }
        if !servers.isEmpty {
            var map: [String: JSONValue] = [:]
            for s in servers { map[keys[s.id]!] = s.kitJSON }
            top["mcpServers"] = .object(map)
        }
        if !animations.isEmpty { top["animations"] = .array(animations.map(\.kitJSON)) }
        return JSONValue.object(top).kitText(pretty: pretty)
    }

    /// The name each server is written under. Two servers with one name would lose one: the later
    /// ones are numbered. Imps refer to servers by these names.
    var serverKeys: [UUID: String] {
        var used = Set<String>(), keys: [UUID: String] = [:]
        for s in servers {
            let base = s.name.isEmpty ? "Tool" : s.name
            var key = base, n = 2
            while used.contains(key) { key = "\(base) \(n)"; n += 1 }
            used.insert(key)
            keys[s.id] = key
        }
        return keys
    }

    /// `imp://add?kit=<base64url JSON>`: the whole kit in a link. Nil when it's too long for one.
    public var link: String? {
        let link = "imp://add?kit=" + Self.base64URL(Data(json(pretty: false).utf8))
        return link.count <= Self.maxLinkLength ? link : nil
    }

    public static let maxLinkLength = 2000

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// Something to know about an item before adding it.
public struct KitWarning: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        /// Code that would run on this Mac.
        case runsCommand
        /// Keys or headers to fill in.
        case needsSecrets
        /// The keys already belong to another trigger.
        case keysInUse
        /// An Imp's service isn't one the user has: it will use their default.
        case brainMissing
        /// An Imp that may operate the Mac through screenshots, clicks and typing.
        case computerControl
    }
    public var kind: Kind
    /// The `Shortcut.id`, `MCPServerConfig.id` or `KitImp.id` it's about.
    public var item: UUID
    public var text: String
    public var id: String { "\(item)-\(kind)" }

    /// Worth a loud banner: running code.
    public var isCaution: Bool { kind == .runsCommand }
}

public enum KitError: LocalizedError, Equatable {
    case empty, notAKit, tooLarge
    case newerVersion(Int)
    case tooMany(String, Int)
    case nothingUsable([String])
    case badAddress(String)
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .empty: String(localized: "There's nothing in it.")
        case .notAKit: String(localized: "That isn't a kit: expected JSON with imps, triggers, animations or mcpServers, a trigger, or an MCP setup.")
        case .tooLarge: String(localized: "That's too big for a kit (the limit is \(Kit.maxBytes / 1024) KB).")
        case .newerVersion(let v): String(localized: "This kit needs a newer Imp (format \(v)). Update Imp: brew upgrade --cask imp.")
        case .tooMany(let what, let limit):
            switch what {
            case "triggers": String(localized: "That has too many triggers (the limit is \(limit)).")
            case "tools": String(localized: "That has too many tools (the limit is \(limit)).")
            case "Imps": String(localized: "That has too many Imps (the limit is \(limit)).")
            case "chats": String(localized: "That has too many chats (the limit is \(limit)).")
            case "animations": String(localized: "That has too many animations (the limit is \(limit)).")
            default: String(localized: "That has too many items (the limit is \(limit)).")
            }
        case .nothingUsable(let problems): String(localized: "Nothing in it could be read. \(problems.prefix(3).joined(separator: " "))")
        case .badAddress(let why), .download(let why): why
        }
    }
}

// MARK: - Where a kit comes from

/// Text to read as a kit, or a web address to download it from.
public enum KitSource: Equatable, Sendable {
    case text(String)
    case remote(URL)

    /// Only https, or http for this Mac itself; no passwords in the address.
    public static func validate(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard let host = url.host?.lowercased(), !host.isEmpty, ["https", "http"].contains(scheme) else {
            throw KitError.badAddress(String(localized: "A kit's address must start with https://."))
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw KitError.badAddress(String(localized: "Only https:// addresses can be loaded (http works for localhost)."))
        }
        guard url.user == nil, url.password == nil else { throw KitError.badAddress(String(localized: "An address with a password in it can't be loaded.")) }
    }

    /// A web address to download a kit from.
    public static func web(_ address: String) throws -> KitSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw KitError.badAddress(String(localized: "That isn't a web address.")) }
        try validate(url)
        return .remote(url)
    }

    /// What was typed or pasted: an `imp://add` link, a web address, or the kit's own text.
    public init(input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("imp://") {
            self = try Self.link(trimmed)
        } else if (lower.hasPrefix("http://") || lower.hasPrefix("https://")) && !trimmed.contains(where: \.isWhitespace) {
            self = try Self.web(trimmed)
        } else {
            self = .text(input)
        }
    }

    /// `imp://add?url=<https address>` or `imp://add?kit=<base64url JSON>`.
    public static func link(_ string: String) throws -> KitSource {
        guard let parts = URLComponents(string: string), parts.scheme == "imp", parts.host == "add" else {
            throw KitError.badAddress(String(localized: "That isn't an imp://add link."))
        }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let address = query["url"] { return try web(address) }
        if let inline = query["kit"] { return .text(try decode(inline: inline)) }
        throw KitError.badAddress(String(localized: "The link has no kit in it (url= or kit=)."))
    }

    /// The JSON text inside an `imp://add?kit=` link.
    public static func decode(inline: String) throws -> String {
        guard inline.utf8.count <= Kit.maxBytes * 4 / 3 + 4 else { throw KitError.tooLarge }
        guard let data = Kit.data(base64URL: inline), let text = String(data: data, encoding: .utf8) else {
            throw KitError.badAddress(String(localized: "The kit in that link is damaged."))
        }
        return text
    }
}

// MARK: - Export: the inverse of what the tools read

extension Hotkey {
    /// How `Hotkey(parsing:)` reads it back: "⌃⌘T".
    var kitText: String { displayString }
}

extension Trigger {
    /// The `when` / `only_if` object `Trigger(tool:)` reads.
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        switch kind {
        case .clicks, .battery, .every, .back, .busy:
            if let number { o["number"] = .number(Double(number)) }
        case .charger, .offline:
            if let flag { o["flag"] = .bool(flag) }
        case .app, .website:
            o["text"] = .string(word)
        case .time:
            o["text"] = .string(Self.clock(minuteOfDay))
        case .hours:
            o["text"] = .string(Self.clock(minuteOfDay) + "-" + Self.clock(endMinute))
        case .keys, .wake, .start, .hot:
            break
        }
        return .object(o)
    }
}

extension Shortcut {
    /// The object `imp_add_trigger` takes. Whose it is isn't part of it: whoever adds it decides.
    var kitJSON: JSONValue {
        var when = trigger.kitJSON
        if case .object(var o) = when, let keys { o["keys"] = .string(keys.kitText); when = .object(o) }
        var o: [String: JSONValue] = ["name": .string(name), "when": when, "with_clipboard": .bool(usesClipboard)]
        if !conditions.isEmpty { o["only_if"] = .array(conditions.map(\.kitJSON)) }
        if command != .ask { o["do"] = .string(command.rawValue) }
        if !prompt.isEmpty { o["prompt"] = .string(prompt) }
        return .object(o)
    }

    var displayLabel: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : name }
}

extension MCPServerConfig {
    /// An `mcpServers` entry, the shape Claude Desktop and Cursor use. Every environment variable
    /// and header value is blanked, and so is anything after a `?` in an address (where keys hide
    /// too): secrets are never exported.
    var kitJSON: JSONValue {
        func blanked(_ map: [String: String]) -> JSONValue { .object(map.mapValues { _ in .string("") }) }
        if transport == .http {
            var o: [String: JSONValue] = ["url": .string(Self.withoutSecrets(url: url))]
            if !headers.isEmpty { o["headers"] = blanked(headers) }
            return .object(o)
        }
        var o: [String: JSONValue] = ["command": .string(command)]
        if !arguments.isEmpty { o["args"] = .array(arguments.map { .string($0) }) }
        if !environment.isEmpty { o["env"] = blanked(environment) }
        return .object(o)
    }

    static func withoutSecrets(url: String) -> String {
        guard var parts = URLComponents(string: url) else { return url }
        parts.user = nil; parts.password = nil
        if let items = parts.queryItems { parts.queryItems = items.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "") } }
        return parts.string ?? url
    }
}

extension JSONValue {
    /// Keys in the order people read them; anything else after, A to Z.
    private static let keyOrder = ["imp", "app", "name", "about", "imps", "triggers", "mcpServers", "animations",
                                   "symbol", "replaces", "starts", "enabled", "beats", "duration", "look", "mood", "glyph", "tilt", "hop", "stretch",
                                   "traits", "lids", "slant", "eyes", "squint", "horns", "blush", "tempo",
                                   "hue", "favoriteHue", "scale", "personality", "instructions", "brain", "model", "service", "baseURL",
                                   "shell", "tools", "exchangesSent", "sendsToolCalls", "chats",
                                   "title", "created", "updated", "turns", "memory", "recap", "messages",
                                   "date", "request", "reply", "failed", "via", "instruction", "copiedText", "sender", "steps",
                                   "icon", "response", "role", "content", "toolCalls", "toolCallID", "id", "arguments",
                                   "when", "only_if", "do", "prompt", "with_clipboard",
                                   "kind", "number", "text", "flag", "keys", "command", "args", "env", "url", "headers"]

    /// JSON text with a stable key order, indented or compact.
    func kitText(pretty: Bool, indent: Int = 0) -> String {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let end = pretty ? "\n" + String(repeating: "  ", count: indent) : ""
        let sep = pretty ? ",\n" : ","
        switch self {
        case .array(let items):
            if items.isEmpty { return "[]" }
            // Beats are short and many: one line each, so an animation reads like a score.
            if !pretty || items.allSatisfy({ $0["duration"] != nil }) {
                let inner = items.map { $0.kitText(pretty: false) }
                if !pretty { return "[" + inner.joined(separator: ",") + "]" }
                return "[\n" + inner.map { pad + $0 }.joined(separator: sep) + end + "]"
            }
            return "[\n" + items.map { pad + $0.kitText(pretty: pretty, indent: indent + 1) }.joined(separator: sep) + end + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let rank = { (k: String) in Self.keyOrder.firstIndex(of: k) ?? Self.keyOrder.count }
            let keys = o.keys.sorted { (rank($0), $0) < (rank($1), $1) }
            let colon = pretty ? ": " : ":"
            return "{" + (pretty ? "\n" : "") + keys.map { pad + Self.quoted($0) + colon + o[$0]!.kitText(pretty: pretty, indent: indent + 1) }.joined(separator: sep) + end + "}"
        case .string(let s): return Self.quoted(s)
        case .number(let n): return Int(exactly: n).map(String.init) ?? String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quoted(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

// MARK: - Adding to the settings

extension ImpPreferences {
    /// The server already in the library that `server` would be a copy of: the same program with
    /// the same arguments, or the same address.
    public func existingServer(like server: MCPServerConfig) -> MCPServerConfig? {
        mcpServers.first { $0.transport == server.transport && (server.transport == .stdio ? $0.commandLine == server.commandLine : $0.url == server.url) }
    }

    public struct KitAdded: Equatable, Sendable {
        public var triggers = 0
        public var servers = 0
        public var animations = 0
        /// The Imps that were hatched (waiting at home, not activated).
        public var imps: [ImportedImp] = []
        /// Servers now in the library that still need keys filled in.
        public var needingSecrets: [UUID] = []
    }

    /// Adds the chosen items of `kit`: its chosen Imps (new ones, with their own triggers and servers),
    /// triggers for `imp` (nil: every Imp), servers to the library (a copy of one already there reuses it)
    /// and switched on for `imp` (nil: for every Imp), unless an Imp of the kit uses them: then for that Imp.
    /// Servers that chosen Imps use come along without being in `chosenServers`.
    /// Chats come back in `KitAdded.imps` to be saved before the Imps appear.
    @discardableResult
    public mutating func add(_ kit: Kit, imps chosenImps: Set<UUID> = [], triggers chosenTriggers: Set<UUID>, servers chosenServers: Set<UUID>,
                             animations chosenAnimations: Set<UUID> = [], for imp: UUID?, withChats: Bool = true) -> KitAdded {
        var added = KitAdded()
        for animation in kit.animations where chosenAnimations.contains(animation.id) {
            adopt(animation, for: imp)
            added.animations += 1
        }
        for var trigger in kit.triggers where chosenTriggers.contains(trigger.id) {
            trigger.performer = imp
            shortcuts.append(trigger)
            added.triggers += 1
        }
        let hatching = kit.imps.filter { chosenImps.contains($0.id) }
        let wanted = chosenServers.union(hatching.flatMap(\.servers))
        var library: [UUID: UUID] = [:]                       // the kit's server id -> the library's
        let users = imp.map { [$0] } ?? self.imps.map(\.id)
        for var server in kit.servers where wanted.contains(server.id) {
            let kitID = server.id
            if let same = existingServer(like: server) { server = same } else { mcpServers.append(server) }
            library[kitID] = server.id
            if chosenServers.contains(kitID) && !hatching.contains(where: { $0.servers.contains(kitID) }) {
                for i in self.imps.indices where users.contains(self.imps[i].id) && !self.imps[i].servers.contains(server.id) {
                    self.imps[i].servers.append(server.id)
                }
            }
            if !server.missingSecrets.isEmpty { added.needingSecrets.append(server.id) }
            added.servers += 1
        }
        for source in hatching { added.imps.append(hatch(source, servers: library, withChats: withChats)) }
        return added
    }
}

extension ImpPreferences {
    /// An animation from a kit, as a new one for `imp` (nil: every Imp): a fresh id, and a name
    /// nobody there has. A replacement takes the place of the one already there.
    mutating func adopt(_ animation: MadeAnimation, for imp: UUID?) {
        var a = animation
        a.id = UUID()
        if a.replaces == nil { a.name = uniqueAnimationName(a.name, imp: imp) }
        save(a, for: imp)
    }
}
