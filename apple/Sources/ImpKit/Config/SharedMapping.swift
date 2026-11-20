import CryptoKit
import Foundation
import ImpCore

/// What the Mac app and `imp` share, read from the files: `imp.json` and the agent files of `~/.agents`, as
/// the core read them.
public struct SharedSnapshot: Hashable, Sendable {
    public var config: JSON = .object([:])
    /// Every agent file, by name: its front matter keys and `body`.
    public var agents: [String: JSON] = [:]
    /// The providers that have a key.
    public var keyed: Set<String> = []
    public var diagnostics: [String] = []
    public var stamp = ""

    public init() {}

    public init(_ s: ConfigSnapshot) {
        config = JSON(text: s.configJson) ?? .object([:])
        agents = Dictionary(s.agents.map { ($0.name, JSON(text: $0.json) ?? .object([:])) }, uniquingKeysWith: { a, _ in a })
        keyed = Set(s.keyedProviders)
        diagnostics = s.diagnostics
        stamp = s.stamp
    }
}

/// What reading gave: the shared part of the preferences, and which provider and which agent file each
/// service and Imp is (the app keeps its own ids; the files keep names).
public struct SharedRead: Sendable {
    public var prefs = ImpPreferences()
    public var providers: [UUID: String] = [:]
    public var files: [UUID: String] = [:]
    public var servers: [UUID: String] = [:]
}

/// What saving must do to the files, worked out against what was read last.
public struct SharedWrite: Sendable {
    /// A merge patch for `imp.json`; nil when nothing in it changes.
    public var config: JSON?
    /// A merge patch for each agent file that changes, by the file's name (a new file is made).
    public var agents: [(name: String, patch: JSON)] = []
    /// Agent files to rename first, with the settings in `imp.json`.
    public var renames: [(old: String, new: String)] = []
    public var removals: [String] = []
    public var providers: [UUID: String] = [:]
    public var files: [UUID: String] = [:]
    public var servers: [UUID: String] = [:]
}

/// The mapping between the app's preferences and the shared configuration (`docs/architecture/configuration.md`).
/// Pure: the files are read and written by `SharedConfigStore`. Only the shared fields are mapped; what
/// belongs to a screen stays in `LocalPreferences`.
public enum SharedMapping {
    // MARK: Names and ids

    /// An id that is the same every time for the same name: services, tool servers and Imps the files have no
    /// id for are known by name, and the app needs a UUID for each.
    static func stableID(_ kind: String, _ key: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("\(kind):\(key)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// A provider's id from the service's name: lowercase letters, digits and dashes (it is part of
    /// `provider/model`, so no `/` or `#`), unique among `taken`.
    public static func providerID(for label: String, avoiding taken: Set<String>) -> String {
        unique(slug(label, fallback: "provider", allowed: { $0.isASCII && ($0.isLetter || $0.isNumber) }, lower: true), avoiding: taken, caseless: true)
    }

    /// An agent's file name from the Imp's name: 1 to 32 letters, digits, `-` and `_`.
    public static func agentName(for name: String, avoiding taken: Set<String>) -> String {
        unique(slug(name, fallback: "imp", allowed: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }, lower: false), avoiding: taken, caseless: true)
    }

    private static func slug(_ text: String, fallback: String, allowed: (Character) -> Bool, lower: Bool) -> String {
        var out = ""
        for c in text.folding(options: .diacriticInsensitive, locale: nil) {
            if allowed(c) { out.append(lower ? Character(c.lowercased()) : c) }
            else if !out.hasSuffix("-"), !out.isEmpty { out.append("-") }
        }
        out = String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? fallback : out
    }

    private static func unique(_ base: String, avoiding taken: Set<String>, caseless: Bool) -> String {
        let used = Set(taken.map { caseless ? $0.lowercased() : $0 })
        func free(_ s: String) -> Bool { !used.contains(caseless ? s.lowercased() : s) }
        if free(base) { return base }
        for i in 2... {
            let suffix = "-\(i)"
            let candidate = String(base.prefix(32 - suffix.count)) + suffix
            if free(candidate) { return candidate }
        }
        return base
    }

    // MARK: Colours

    /// The swatch a hue is written as in an agent's `color` (`#rrggbb`): a fixed saturation and brightness.
    public static func hex(forHue hue: Double) -> String {
        let h = (hue - hue.rounded(.down)) * 6, s = 0.7, v = 0.9
        let f = h - h.rounded(.down), p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        func byte(_ x: Double) -> Int { Int((x * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// The hue of a `#rrggbb` colour, or nil when it is not one.
    public static func hue(fromHex text: String) -> Double? {
        guard text.count == 7, text.hasPrefix("#"), let n = Int(text.dropFirst(), radix: 16) else { return nil }
        let r = Double((n >> 16) & 255) / 255, g = Double((n >> 8) & 255) / 255, b = Double(n & 255) / 255
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        guard d > 0 else { return 0 }
        let h: Double = hi == r ? ((g - b) / d).truncatingRemainder(dividingBy: 6) : hi == g ? (b - r) / d + 2 : (r - g) / d + 4
        let turn = h / 6
        return turn < 0 ? turn + 1 : turn
    }

    // MARK: Rules

    static func rules(_ json: JSON?) -> [PermissionRule] {
        (json?.array ?? []).compactMap { r in
            guard let action = r["action"]?.string, let effect = r["effect"]?.string else { return nil }
            let e: PermissionEffect? = switch effect { case "allow": .allow; case "ask": .ask; case "deny": .deny; default: nil }
            return e.map { PermissionRule(action: action, resource: r["resource"]?.string ?? "*", effect: $0) }
        }
    }

    static func json(_ rules: [PermissionRule]) -> JSON {
        .array(rules.map { r in
            .object(["action": .string(r.action), "resource": .string(r.resource),
                     "effect": .string(r.effect == .allow ? "allow" : r.effect == .ask ? "ask" : "deny")])
        })
    }

    /// Whether the agent may do `action` on `resource` (not denied).
    static func allowed(_ global: [PermissionRule], _ own: [PermissionRule], _ action: String, _ resource: String = "*") -> Bool {
        permissionDecide(global: global, own: own, action: action, resource: resource) != .deny
    }

    // MARK: Reading

    /// Reads the shared part of the preferences. The Imps are the agents that are `primary` or `all`, in the
    /// order of their names (the app puts its own order over it, see `LocalPreferences`).
    public static func read(_ s: SharedSnapshot) -> SharedRead {
        var out = SharedRead()
        var p = ImpPreferences()
        let c = s.config
        let (ai, providers) = readAI(c, keyed: s.keyed)
        p.ai = ai
        out.providers = providers
        p.mcpServers = (c["mcp"]?.object ?? [:]).keys.sorted().compactMap { readServer(name: $0, c["mcp"]?[$0]) }
        out.servers = Dictionary(p.mcpServers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        p.shortcuts = (c["triggers"]?.array ?? []).compactMap { $0.decoded(Shortcut.self) }.filter(\.isValid)
        if let list = c["animations"]?.array { p.customAnimations = list.compactMap { $0.decoded(MadeAnimation.self) } }
        if let r = c["requests"] {
            var l = RequestLimits.standard
            if let v = r["timeoutSeconds"]?.double { l.timeoutSeconds = v }
            if let v = r["retries"]?.int { l.retries = v }
            if let v = r["retryDelaySeconds"]?.double { l.retryDelaySeconds = v }
            if let v = r["backoff"]?.double { l.backoff = v }
            p.requests = l
        }
        if let t = c["talk"] {
            if let v = t["place"]?.string.flatMap(ImpTalk.init) { p.impTalk = v }
            if let v = t["threading"]?.string.flatMap(TalkThreading.init) { p.talkThreading = v }
            if let v = t["waiting"]?.string.flatMap(TalkWaiting.init) { p.talkWaiting = v }
            if let v = t["windowMinutes"]?.int { p.talkWindowMinutes = v }
        }
        if let hop = c["link"]?["hop"]?.string { p.hop = hop }
        if let v = c["link"]?["deviceTools"]?.decoded(DeviceToolLimits.self) { p.deviceToolLimits = v }
        let global = rules(c["permissions"])
        for name in s.agents.keys.sorted() {
            guard let agent = s.agents[name], isImp(agent) else { continue }
            let imp = readImp(name: name, agent: agent, extras: c["imps"]?[name], global: global, servers: p.mcpServers, providers: out.providers)
            out.files[imp.id] = name
            p.imps.append(imp)
        }
        out.prefs = p
        return out
    }

    /// An agent the Mac shows as an Imp: `primary` or `all`, loaded and not hidden.
    static func isImp(_ agent: JSON) -> Bool {
        let mode = agent["mode"]?.string ?? "all"
        return (mode == "primary" || mode == "all") && agent["disabled"]?.bool != true && agent["hidden"]?.bool != true
    }

    private static func readAI(_ c: JSON, keyed: Set<String>) -> (AIConfig, [UUID: String]) {
        var ai = AIConfig()
        var ids: [UUID: String] = [:]
        let ref = c["model"]?.string.flatMap { try? modelRefParse(text: $0) }
        for id in (c["providers"]?.object ?? [:]).keys.sorted() {
            let node = c["providers"]?[id]
            let uuid = stableID("provider", id)
            var service = Service(id: uuid, name: node?["name"]?.string ?? id, baseURL: node?["options"]?["baseURL"]?.string ?? "")
            service.model = node?["defaultModel"]?.string ?? ""
            if let ref, ref.provider == id { service.model = ref.model }
            ai.services.append(service)
            ids[uuid] = id
        }
        if let ref, let service = ai.services.first(where: { ids[$0.id] == ref.provider }) { ai.brain.service = service.id }
        else { ai.brain.service = ai.services.first?.id }
        return (ai, ids)
    }

    static func readServer(name: String, _ node: JSON?) -> MCPServerConfig? {
        guard let node else { return nil }
        let id = stableID("mcp", name)
        var s: MCPServerConfig
        switch node["type"]?.string {
        case "local":
            let command = (node["command"]?.array ?? []).compactMap(\.string)
            guard let program = command.first else { return nil }
            s = MCPServerConfig(name: name, transport: .stdio, command: program, arguments: Array(command.dropFirst()),
                                environment: (node["environment"]?.object ?? [:]).compactMapValues(\.string))
        case "remote":
            guard let url = node["url"]?.string else { return nil }
            s = MCPServerConfig(name: name, transport: .http, url: url, headers: (node["headers"]?.object ?? [:]).compactMapValues(\.string))
        default: return nil
        }
        s.id = id
        s.isEnabled = node["disabled"]?.bool != true
        return s
    }

    static func readImp(name: String, agent: JSON, extras: JSON?, global: [PermissionRule], servers: [MCPServerConfig],
                        providers: [UUID: String]) -> ImpProfile {
        let own = rules(agent["permissions"])
        let id = extras?["id"]?.string.flatMap(UUID.init) ?? stableID("imp", name)
        var skin = 0.0
        if let color = agent["color"]?.string, let h = hue(fromHex: color) {
            if let kept = extras?["hue"]?.double, hex(forHue: kept) == color { skin = kept } else { skin = h }
        } else if let kept = extras?["hue"]?.double { skin = kept }
        var imp = ImpProfile(id: id, name: name, hue: skin, favoriteHue: extras?["favoriteHue"]?.double ?? skin,
                             scale: extras?["size"]?.double ?? 1, personality: agent["body"]?.string ?? "")
        imp.about = agent["description"]?.string
        if let texts = agent["toolText"]?.object {
            imp.toolText = texts.compactMapValues { v in
                let text = ToolText(name: v["name"]?.string, description: v["description"]?.string)
                return text.isEmpty ? nil : text
            }
        }
        imp.character = extras?["character"]?.decoded(ImpTraits.self)
        if let v = extras?["instructions"]?.string { imp.instructions = v }
        imp.sendsToolCalls = extras?["memory"]?["sendsToolCalls"]?.bool
        imp.exchangesSent = extras?["memory"]?["exchanges"]?.int
        imp.newChatAtTokens = extras?["memory"]?["newChatAtTokens"]?.int
        if let list = extras?["animations"]?.array { imp.ownAnimations = list.compactMap { $0.decoded(MadeAnimation.self) } }
        if extras?["noBrain"]?.bool == true { imp.brain = .notChosen }
        else if let ref = agent["model"]?.string.flatMap({ try? modelRefParse(text: $0) }) {
            imp.brain = Brain(service: providers.first { $0.value == ref.provider }?.key ?? stableID("provider", ref.provider), model: ref.model)
        }
        for group in ImpToolGroup.allCases { imp.setUses(group, allowed(global, own, group.rawValue)) }
        imp.usesShell = allowed(global, own, "shell")
        imp.servers = servers.filter { allowed(global, own, "mcp", "\($0.name)/*") }.map(\.id)
        for r in own where r.effect == .deny && r.resource != "*" {
            if let group = ImpToolGroup(rawValue: r.action) {
                imp.setUses(tool: ToolRegistry.ownID(group, tool: r.resource), false)
            } else if r.action == "mcp", let slash = r.resource.firstIndex(of: "/") {
                let server = String(r.resource[..<slash]), tool = String(r.resource[r.resource.index(after: slash)...])
                if tool != "*" { imp.setUses(tool: ToolRegistry.mcpID(server: server, tool: tool), false) }
            }
        }
        return imp
    }

    // MARK: Writing

    /// What saving `prefs` changes in the files, given what was read last (`base`, with the ids `previous` knew).
    /// Only what the shared configuration holds is looked at, and only what differs is in the result.
    public static func write(_ prefs: ImpPreferences, base: SharedSnapshot, previous: SharedRead) -> SharedWrite {
        var out = SharedWrite()
        var patch: [String: JSON] = [:]
        let baseConfig = base.config
        // What the files already say, as the app reads it: a section the app holds unchanged is left as written
        // (a default is not a reason to remove what the file spells out, nor to undo what `imp` changed since).
        let current = read(base).prefs

        // Providers (services) and the default model.
        var taken = Set((baseConfig["providers"]?.object ?? [:]).keys)
        var providerPatch: [String: JSON] = [:]
        let defaultRef = modelRef(prefs.ai.brain, in: prefs.ai, providers: Dictionary(uniqueKeysWithValues: prefs.ai.services.compactMap { s in
            (previous.providers[s.id] ?? out.providers[s.id]).map { (s.id, $0) } }), keeping: baseConfig["model"]?.string, defaultModel: true)
            .flatMap { try? modelRefParse(text: $0) }
        for service in prefs.ai.services {
            let id = previous.providers[service.id] ?? providerID(for: service.label, avoiding: taken)
            taken.insert(id)
            out.providers[service.id] = id
            let name = service.name.trimmingCharacters(in: .whitespaces)
            var node: [String: JSON] = [
                "name": name.isEmpty || name == id ? .null : .string(name),
                "options": .object(["baseURL": .string(service.baseURL)]),
            ]
            // The default Brain's own model is `model`'s; a provider holds a model of its own only for when it is picked.
            let isDefaults = defaultRef?.provider == id && defaultRef?.model == service.model && baseConfig["providers"]?[id]?["defaultModel"] == nil
            if !isDefaults {
                node["defaultModel"] = .optional(service.model.isEmpty ? nil : service.model)
                if !service.model.isEmpty { node["models"] = .object([service.model: .object([:])]) }
            }
            providerPatch[id] = .object(node)
        }
        for old in (baseConfig["providers"]?.object ?? [:]).keys where !out.providers.values.contains(old) { providerPatch[old] = .null }
        patch["providers"] = providerPatch.isEmpty ? .null : .object(providerPatch)
        patch["model"] = .optional(modelRef(prefs.ai.brain, in: prefs.ai, providers: out.providers, keeping: baseConfig["model"]?.string, defaultModel: true))

        // Tool servers.
        var serverPatch: [String: JSON] = [:]
        var renamedServers: [String: String] = [:]
        for s in prefs.mcpServers {
            out.servers[s.id] = s.name
            if let old = previous.servers[s.id], old != s.name { renamedServers[old] = s.name }
        }
        for s in prefs.mcpServers { serverPatch[s.name] = writeServer(s) }
        for old in (baseConfig["mcp"]?.object ?? [:]).keys where !serverPatch.keys.contains(old) { serverPatch[old] = .null }
        patch["mcp"] = serverPatch.isEmpty ? .null : .object(serverPatch)

        if prefs.shortcuts != current.shortcuts {
            patch["triggers"] = prefs.shortcuts.isEmpty ? .null : .array(prefs.shortcuts.map { JSON(encoding: $0) })
        }
        if prefs.customAnimations != current.customAnimations {
            let library = prefs.customAnimations ?? []
            patch["animations"] = library.isEmpty ? .null : .array(library.map { JSON(encoding: $0) })
        }
        if prefs.requests != current.requests {
            patch["requests"] = prefs.requests == .standard ? .null : .object([
                "timeoutSeconds": .number(prefs.requests.timeoutSeconds), "retries": .number(Double(prefs.requests.retries)),
                "retryDelaySeconds": .number(prefs.requests.retryDelaySeconds), "backoff": .number(prefs.requests.backoff),
            ])
        }
        var talkNode: [String: JSON] = [:]
        if prefs.impTalk != current.impTalk { talkNode["place"] = prefs.impTalk == .own ? .null : .string(prefs.impTalk.rawValue) }
        if prefs.talkThreading != current.talkThreading { talkNode["threading"] = prefs.talkThreading == .decides ? .null : .string(prefs.talkThreading.rawValue) }
        if prefs.talkWaiting != current.talkWaiting { talkNode["waiting"] = prefs.talkWaiting == .decides ? .null : .string(prefs.talkWaiting.rawValue) }
        if prefs.talkWindowMinutes != current.talkWindowMinutes { talkNode["windowMinutes"] = prefs.talkWindowMinutes == 60 ? .null : .number(Double(prefs.talkWindowMinutes)) }
        if !talkNode.isEmpty { patch["talk"] = .object(talkNode) }
        var linkNode: [String: JSON] = [:]
        if prefs.hop != current.hop { linkNode["hop"] = prefs.hop == ServerKind.hop.defaultAddress ? .null : .string(prefs.hop) }
        if prefs.deviceToolLimits != current.deviceToolLimits {
            linkNode["deviceTools"] = prefs.deviceToolLimits == DeviceToolLimits() ? .null : JSON(encoding: prefs.deviceToolLimits)
        }
        if !linkNode.isEmpty { patch["link"] = .object(linkNode) }

        // Imps: agent files, and their extras in `imp.json`.
        let global = rules(baseConfig["permissions"])
        let fileNames = Set(base.agents.keys)
        var takenFiles = fileNames
        var impsPatch: [String: JSON] = [:]
        var present: Set<String> = []
        for imp in prefs.imps {
            let old = previous.files[imp.id]
            var file = old ?? agentName(for: imp.name, avoiding: takenFiles)
            let wanted = imp.name
            if let old, old != wanted, wanted == agentName(for: wanted, avoiding: takenFiles.subtracting([old])) {
                file = wanted
                out.renames.append((old, wanted))
                takenFiles.remove(old)
            }
            takenFiles.insert(file)
            out.files[imp.id] = file
            present.insert(file)
            let baseAgent = base.agents[old ?? file]
            let agentPatch = writeAgent(imp, base: baseAgent, global: global, servers: prefs.mcpServers, renamed: renamedServers,
                                        providers: out.providers, ai: prefs.ai, isNew: baseAgent == nil)
            if let baseAgent {
                if let kept = agentPatch.pruned(against: baseAgent), baseAgent.merged(with: kept) != baseAgent { out.agents.append((file, kept)) }
            } else {
                out.agents.append((file, agentPatch))
            }
            // An Imp the files describe fully needs no settings of its own.
            let merged = (baseAgent ?? .object([:])).merged(with: agentPatch)
            let plain = readImp(name: file, agent: merged, extras: nil, global: global, servers: prefs.mcpServers, providers: out.providers)
            if baseConfig["imps"]?[old ?? file] != nil || plain != imp {
                impsPatch[file] = writeExtras(imp, color: merged["color"]?.string, had: baseConfig["imps"]?[old ?? file])
            }
        }
        for (id, file) in previous.files where out.files[id] == nil && base.agents[file] != nil {
            out.removals.append(file)
            impsPatch[file] = .null
        }
        // Extras of an Imp that was renamed are moved by the core; the old key is gone with it.
        for r in out.renames where impsPatch[r.old] == nil { impsPatch[r.old] = .null }
        patch["imps"] = impsPatch.isEmpty ? .null : .object(impsPatch)

        // Only what differs from what was read.
        var comparable = baseConfig
        for r in out.renames {
            if let moved = comparable["imps"]?[r.old] { comparable = comparable.merged(with: .object(["imps": .object([r.old: .null, r.new: moved])])) }
        }
        if let kept = JSON.object(patch).pruned(against: comparable), comparable.merged(with: kept) != comparable { out.config = kept }
        return out
    }

    /// The `provider/model#variant` of a brain (the default one, or an Imp's own), or nil when it names none.
    /// A variant the file had for the same model is kept.
    static func modelRef(_ brain: Brain, in ai: AIConfig, providers: [UUID: String], keeping old: String?, defaultModel: Bool = false) -> String? {
        guard !brain.isNotChosen, let service = ai.service(in: brain), let provider = providers[service.id] else { return nil }
        let model = defaultModel ? ai.model() : (brain.model.trimmingCharacters(in: .whitespaces).isEmpty ? service.model : brain.model)
        guard !model.isEmpty else { return nil }
        let variant = old.flatMap { try? modelRefParse(text: $0) }.flatMap { $0.provider == provider && $0.model == model ? $0.variant : nil }
        return modelRefFormat(parts: ModelParts(provider: provider, model: model, variant: variant))
    }

    static func writeServer(_ s: MCPServerConfig) -> JSON {
        let disabled: JSON = s.isEnabled ? .null : .bool(true)
        switch s.transport {
        case .stdio:
            return .object(["type": .string("local"), "command": .array(([s.command] + s.arguments).map(JSON.string)),
                            "environment": s.environment.isEmpty ? .null : .object(s.environment.mapValues(JSON.string)),
                            "disabled": disabled, "url": .null, "headers": .null, "oauth": .null])
        case .http:
            return .object(["type": .string("remote"), "url": .string(s.url),
                            "headers": s.headers.isEmpty ? .null : .object(s.headers.mapValues(JSON.string)),
                            "disabled": disabled, "command": .null, "environment": .null, "cwd": .null])
        }
    }

    /// The settings an Imp has besides its agent file. The hue is left out when the file's colour says it, and
    /// the favourite hue and size when they are the plain ones.
    static func writeExtras(_ imp: ImpProfile, color: String?, had: JSON?) -> JSON {
        let memory: [String: JSON] = ["exchanges": .optional(imp.exchangesSent), "sendsToolCalls": .optional(imp.sendsToolCalls),
                                      "newChatAtTokens": .optional(imp.newChatAtTokens)]
        // A plain value is written only when the file has the key (so it is not left behind), else it is left out.
        func plain(_ key: String, _ value: Double, _ isPlain: Bool) -> JSON? { isPlain && had?[key] == nil ? nil : .number(value) }
        let numbers: [String: JSON?] = [
            "hue": plain("hue", imp.hue, (color.flatMap(hue(fromHex:)) ?? 0) == imp.hue),
            "favoriteHue": plain("favoriteHue", imp.favoriteHue, imp.favoriteHue == imp.hue),
            "size": plain("size", imp.scale, imp.scale == 1),
        ]
        return .object(numbers.compactMapValues { $0 }.merging([
            "id": .string(imp.id.uuidString.lowercased()),
            "character": imp.character.map { JSON(encoding: $0) } ?? .null,
            "instructions": .optional(imp.instructions),
            "memory": memory.values.allSatisfy { $0 == .null } ? .null : .object(memory),
            "animations": (imp.ownAnimations ?? []).isEmpty ? .null : .array((imp.ownAnimations ?? []).map { JSON(encoding: $0) }),
            "noBrain": imp.brain?.isNotChosen == true ? .bool(true) : .null,
        ], uniquingKeysWith: { a, _ in a }))
    }

    static func writeAgent(_ imp: ImpProfile, base: JSON?, global: [PermissionRule], servers: [MCPServerConfig],
                           renamed: [String: String], providers: [UUID: String], ai: AIConfig, isNew: Bool) -> JSON {
        var own = rules(base?["permissions"])
        // A tool server renamed in the library: the rules that named it follow.
        for (old, new) in renamed {
            own = own.map { r in
                guard r.action == "mcp", r.resource.hasPrefix(old + "/") else { return r }
                return PermissionRule(action: r.action, resource: new + r.resource.dropFirst(old.count), effect: r.effect)
            }
        }
        for group in ImpToolGroup.allCases where allowed(global, own, group.rawValue) != imp.uses(group) {
            own = permissionSet(global: global, own: own, action: group.rawValue, resource: "*", on: imp.uses(group))
        }
        if allowed(global, own, "shell") != imp.usesShell { own = permissionSet(global: global, own: own, action: "shell", resource: "*", on: imp.usesShell) }
        for s in servers {
            let on = imp.servers.contains(s.id)
            if allowed(global, own, "mcp", "\(s.name)/*") != on { own = permissionSet(global: global, own: own, action: "mcp", resource: "\(s.name)/*", on: on) }
        }
        // Single tools: the rules the file has for one tool are replaced by the switches.
        let names = Set(servers.map(\.name))
        func single(_ r: PermissionRule) -> String? {
            guard r.effect == .deny, r.resource != "*" else { return nil }
            if let group = ImpToolGroup(rawValue: r.action) { return ToolRegistry.ownID(group, tool: r.resource) }
            if r.action == "mcp", let name = names.sorted(by: { $0.count > $1.count }).first(where: { r.resource.hasPrefix($0 + "/") }) {
                let tool = String(r.resource.dropFirst(name.count + 1))
                return tool == "*" ? nil : ToolRegistry.mcpID(server: name, tool: tool)
            }
            return nil
        }
        let wantedOff = imp.disabledTools
        for r in own {
            if let id = single(r), !wantedOff.contains(id) { own = permissionSet(global: global, own: own, action: r.action, resource: r.resource, on: true) }
        }
        let haveOff = Set(own.compactMap(single))
        for id in wantedOff.subtracting(haveOff) {
            if id.hasPrefix("own."), let group = ImpToolGroup.allCases.first(where: { id.hasPrefix(ToolRegistry.ownGroupID($0) + ".") }) {
                own = permissionSet(global: global, own: own, action: group.rawValue, resource: String(id.dropFirst(ToolRegistry.ownGroupID(group).count + 1)), on: false)
            } else if let name = names.sorted(by: { $0.count > $1.count }).first(where: { id.hasPrefix(ToolRegistry.mcpGroupID(server: $0) + ".") }) {
                own = permissionSet(global: global, own: own, action: "mcp", resource: "\(name)/" + id.dropFirst(ToolRegistry.mcpGroupID(server: name).count + 1), on: false)
            }
        }
        var patch: [String: JSON] = [
            "body": .string(imp.personality),
            "description": .optional(imp.about),
            "permissions": own.isEmpty ? .null : json(own),
        ]
        // The colour stays as the file has it unless the hue changed (a hue is a wheel, a colour is a swatch of it).
        let kept = base?["color"]?.string.flatMap { c in hue(fromHex: c).map { ($0, c) } }
        if let kept {
            if imp.hue != kept.0, hex(forHue: imp.hue) != kept.1 { patch["color"] = .string(hex(forHue: imp.hue)) }
        } else if imp.hue != 0 || base?["color"] != nil {
            patch["color"] = .string(hex(forHue: imp.hue))
        }
        // What was written over the tools' names and descriptions: one object per tool, and the ones that went are cleared.
        let oldTexts = base?["toolText"]?.object ?? [:]
        var texts: [String: JSON] = [:]
        for (id, t) in imp.toolText {
            texts[id] = .object(["name": .optional(t.name), "description": .optional(t.description)])
        }
        for id in oldTexts.keys where texts[id] == nil { texts[id] = .null }
        if imp.toolText.isEmpty { if !oldTexts.isEmpty { patch["toolText"] = .null } } else { patch["toolText"] = .object(texts) }
        if isNew { patch["mode"] = .string("primary") }
        patch["model"] = imp.brain.flatMap { modelRef($0, in: ai, providers: providers, keeping: base?["model"]?.string) }.map(JSON.string) ?? .null
        return .object(patch)
    }
}
