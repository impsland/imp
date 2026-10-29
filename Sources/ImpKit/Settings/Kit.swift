import Foundation

/// A kit: triggers and borrowed tools (MCP servers) packaged as one piece of JSON, to share and to
/// add without clicking through Settings.
///
///     { "imp": 1, "name": "Morning helper", "about": "optional text",
///       "triggers": [ { …the arguments of imp_add_trigger… } ],
///       "mcpServers": { "name": { "command": …, "args": […], "env": {…} } or { "url": …, "headers": {…} } } }
///
/// Parsing reuses the parsers behind the Imp's own tools (`Shortcut(tool:imp:)`, `MCPServerConfig.parse(setup:)`),
/// and also takes what people paste without the wrapper: a plain MCP snippet, or a trigger (or a list of them).
/// Nothing in a kit is applied by parsing it: the app shows it for review first.
public struct Kit: Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxBytes = 512 * 1024
    public static let maxTriggers = 50
    public static let maxServers = 20

    public var name: String
    public var about: String
    public var triggers: [Shortcut]
    public var servers: [MCPServerConfig]
    /// Items that couldn't be read ("Trigger 2: Unknown trigger kind …"). The rest of the kit still stands.
    public var problems: [String]

    public init(name: String = "", about: String = "", triggers: [Shortcut] = [], servers: [MCPServerConfig] = [], problems: [String] = []) {
        self.name = name; self.about = about; self.triggers = triggers; self.servers = servers; self.problems = problems
    }

    public var itemCount: Int { triggers.count + servers.count }

    // MARK: Reading

    /// A kit from pasted or downloaded text. Throws when the text isn't a kit at all; items that
    /// are bad end up in `problems` instead.
    public static func parse(_ text: String) throws -> Kit {
        guard text.utf8.count <= maxBytes else { throw KitError.tooLarge }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KitError.empty }
        var kit: Kit
        if trimmed.first == "[" {
            guard let list = (try? JSONValue(jsonString: trimmed))?.array else { throw KitError.notAKit }
            kit = Kit()
            kit.read(triggers: list)
        } else if trimmed.first == "{", let json = try? JSONValue(jsonString: trimmed) {
            if json["imp"] != nil || json["triggers"] != nil {
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
        guard kit.itemCount > 0 else {
            throw kit.problems.isEmpty ? KitError.empty : KitError.nothingUsable(kit.problems)
        }
        return kit
    }

    private static func envelope(_ json: JSONValue) throws -> Kit {
        if let version = json["imp"] {
            guard let v = version.int, v >= 1 else { throw KitError.notAKit }
            guard v <= currentVersion else { throw KitError.newerVersion(v) }
        }
        var kit = Kit(name: json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                      about: json["about"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        if let list = json["triggers"] {
            if let array = list.array { kit.read(triggers: array) } else { kit.problems.append("“triggers” should be a list.") }
        }
        if let map = json["mcpServers"] {
            if case .object(let entries) = map { kit.read(servers: entries) } else { kit.problems.append("“mcpServers” should be an object.") }
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
                let label = item["name"]?.string.map { "Trigger \(i + 1) (“\($0)”)" } ?? "Trigger \(i + 1)"
                problems.append("\(label): \(Self.message(error))")
            }
        }
    }

    private mutating func read(servers entries: [String: JSONValue]) {
        for key in entries.keys.sorted() {
            // One entry at a time, through the same parser the Tools tab's Paste uses; a server
            // named like a wrapper key ("mcp") is no trouble that way.
            guard case .object = entries[key]!, var server = MCPServerConfig.parse(setup: entries[key]!.jsonString).first else {
                problems.append("Tool “\(key)”: needs a `command` (a program) or a `url` (a web address).")
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
    public func warnings(existing: [Shortcut] = []) -> [KitWarning] {
        var out: [KitWarning] = []
        for server in servers {
            if server.transport == .stdio {
                out.append(KitWarning(kind: .runsCommand, item: server.id, text: "“\(server.name)” runs a command on your Mac: \(server.commandLine)"))
            }
            if !server.missingSecrets.isEmpty {
                out.append(KitWarning(kind: .needsSecrets, item: server.id,
                                      text: "“\(server.name)” needs you to fill in: \(server.missingSecrets.joined(separator: ", "))"))
            }
        }
        var taken: [Hotkey: String] = [:]
        for s in existing { if let keys = s.keys { taken[keys] = "“\(s.displayLabel)”" } }
        for s in triggers {
            guard let keys = s.keys else { continue }
            if let other = taken[keys] {
                out.append(KitWarning(kind: .keysInUse, item: s.id, text: "\(keys.displayString) is already used by \(other)"))
            }
            taken[keys] = "another trigger in this kit"
        }
        return out
    }

    // MARK: Writing

    /// The kit as JSON text: readable, or compact for a link. Secrets are never in it (`KitExport`).
    public func json(pretty: Bool = true) -> String {
        var top: [String: JSONValue] = ["imp": .number(Double(Self.currentVersion))]
        if !name.isEmpty { top["name"] = .string(name) }
        if !about.isEmpty { top["about"] = .string(about) }
        if !triggers.isEmpty { top["triggers"] = .array(triggers.map(\.kitJSON)) }
        if !servers.isEmpty {
            // Two servers with one name would lose one: number the later ones.
            var map: [String: JSONValue] = [:]
            for s in servers {
                var key = s.name.isEmpty ? "Tool" : s.name, n = 2
                while map[key] != nil { key = "\(s.name) \(n)"; n += 1 }
                map[key] = s.kitJSON
            }
            top["mcpServers"] = .object(map)
        }
        return JSONValue.object(top).kitText(pretty: pretty)
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
    }
    public var kind: Kind
    /// The `Shortcut.id` or `MCPServerConfig.id` it's about.
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
        case .empty: "There's nothing in it."
        case .notAKit: "That isn't a kit: expected JSON with triggers or mcpServers, a trigger, or an MCP setup."
        case .tooLarge: "That's too big for a kit (the limit is \(Kit.maxBytes / 1024) KB)."
        case .newerVersion(let v): "This kit is version \(v). This Imp reads version \(Kit.currentVersion): update Imp to use it."
        case .tooMany(let what, let limit): "That has too many \(what) (the limit is \(limit))."
        case .nothingUsable(let problems): "Nothing in it could be read. " + problems.prefix(3).joined(separator: " ")
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
            throw KitError.badAddress("A kit's address must start with https://.")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(host) else {
            throw KitError.badAddress("Only https:// addresses can be loaded (http works for localhost).")
        }
        guard url.user == nil, url.password == nil else { throw KitError.badAddress("An address with a password in it can't be loaded.") }
    }

    /// A web address to download a kit from.
    public static func web(_ address: String) throws -> KitSource {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw KitError.badAddress("That isn't a web address.") }
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
            throw KitError.badAddress("That isn't an imp://add link.")
        }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let address = query["url"] { return try web(address) }
        if let inline = query["kit"] { return .text(try decode(inline: inline)) }
        throw KitError.badAddress("The link has no kit in it (url= or kit=).")
    }

    /// The JSON text inside an `imp://add?kit=` link.
    public static func decode(inline: String) throws -> String {
        guard inline.utf8.count <= Kit.maxBytes * 4 / 3 + 4 else { throw KitError.tooLarge }
        guard let data = Kit.data(base64URL: inline), let text = String(data: data, encoding: .utf8) else {
            throw KitError.badAddress("The kit in that link is damaged.")
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
    private static let keyOrder = ["imp", "name", "about", "triggers", "mcpServers", "when", "only_if", "do", "prompt", "with_clipboard",
                                   "kind", "number", "text", "flag", "keys", "command", "args", "env", "url", "headers"]

    /// JSON text with a stable key order, indented or compact.
    func kitText(pretty: Bool, indent: Int = 0) -> String {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let end = pretty ? "\n" + String(repeating: "  ", count: indent) : ""
        let sep = pretty ? ",\n" : ","
        switch self {
        case .array(let items):
            if items.isEmpty { return "[]" }
            if !pretty {
                return "[" + items.map { $0.kitText(pretty: pretty) }.joined(separator: ",") + "]"
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
        /// Servers now in the library that still need keys filled in.
        public var needingSecrets: [UUID] = []
    }

    /// Adds the chosen items of `kit`: triggers for `imp` (nil: every Imp), servers to the library
    /// (a copy of one already there reuses it) and switched on for `imp` (nil: for every Imp).
    @discardableResult
    public mutating func add(_ kit: Kit, triggers chosenTriggers: Set<UUID>, servers chosenServers: Set<UUID>, for imp: UUID?) -> KitAdded {
        var added = KitAdded()
        for var trigger in kit.triggers where chosenTriggers.contains(trigger.id) {
            trigger.performer = imp
            shortcuts.append(trigger)
            added.triggers += 1
        }
        let users = imp.map { [$0] } ?? imps.map(\.id)
        for var server in kit.servers where chosenServers.contains(server.id) {
            if let same = existingServer(like: server) { server = same } else { mcpServers.append(server) }
            for i in imps.indices where users.contains(imps[i].id) && !imps[i].servers.contains(server.id) { imps[i].servers.append(server.id) }
            if !server.missingSecrets.isEmpty { added.needingSecrets.append(server.id) }
            added.servers += 1
        }
        return added
    }
}
