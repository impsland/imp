import Foundation

/// An Imp inside a kit: everything that makes it itself, in a form that moves between Macs.
///
/// This is a file format of its own, written and read field by field (never `ImpProfile`'s own
/// encoding), so changing how an Imp is stored never changes what a shared file looks like. Nothing
/// local travels: no ids, no keys, no folders, no place on screen, not whether it was out on the desktop.
///
///     { "name": "Pip", "hue": 0.57, "favoriteHue": 0.9, "scale": 1.0,
///       "personality": "…", "instructions": "…",                       // instructions: omitted = built-in
///       "brain": { "model": "gpt-4o", "service": { "name": "OpenAI", "baseURL": "https://api.openai.com/v1" } },
///       "shell": true,
///       "tools": { "body": true, "senses": true, "setup": true, "troupe": true, "computer": false },
///       "exchangesSent": 20, "sendsToolCalls": true,
///       "mcpServers": ["Notes"],                                        // names in the kit's top-level mcpServers
///       "triggers": [ { …as in a kit… } ],
///       "chats": [ { "title", "created", "updated", "turns": […], "memory": { "recap", "messages": […] } } ],
///       "traits": { "lids": 0.3, "slant": -0.2, "tempo": 0.8 },                // its character, see `ImpTraits`
///       "animations": [ { …as in a kit… } ] }                                // its own
///
/// Only `name` is required. A missing field takes the default a new Imp has, an unknown one is ignored.
/// Chats with other Imps aren't exported (they refer to Imps by local id); pictures aren't either
/// (they're files in the Imp's folder).
public struct KitImp: Equatable, Sendable, Identifiable {
    /// Only for the review sheet: never written to a file.
    public var id = UUID()
    public var name: String
    public var hue: Double
    public var favoriteHue: Double
    public var scale: Double
    public var personality: String
    /// Nil: the built-in instructions.
    public var instructions: String?
    public var brain: KitBrain?
    public var usesShell: Bool
    public var tools: [ImpToolGroup: Bool]
    public var exchangesSent: Int?
    public var sendsToolCalls: Bool
    /// `MCPServerConfig.id`s in the kit's `servers`.
    public var servers: [UUID]
    /// Its own triggers (their performer is whoever it becomes).
    public var triggers: [Shortcut]
    public var chats: [Chat]
    /// Its character (see `ImpTraits`) and its own animations.
    public var traits: ImpTraits = .plain
    public var animations: [MadeAnimation] = []

    public init(name: String, hue: Double = ImpProfile.defaultHue, favoriteHue: Double? = nil, scale: Double = 1, personality: String = "",
                instructions: String? = nil, brain: KitBrain? = nil, usesShell: Bool = true, tools: [ImpToolGroup: Bool] = [:],
                exchangesSent: Int? = nil, sendsToolCalls: Bool = true, servers: [UUID] = [], triggers: [Shortcut] = [], chats: [Chat] = []) {
        self.name = name; self.hue = hue; self.favoriteHue = favoriteHue ?? Self.otherHue(than: hue); self.scale = scale
        self.personality = personality; self.instructions = instructions; self.brain = brain; self.usesShell = usesShell
        self.tools = tools; self.exchangesSent = exchangesSent; self.sendsToolCalls = sendsToolCalls
        self.servers = servers; self.triggers = triggers; self.chats = chats
    }

    /// An Imp as it would be shared. `prefs` resolves its service and its triggers.
    public init(_ profile: ImpProfile, in prefs: ImpPreferences, chats: [Chat] = []) {
        var brain: KitBrain?
        if let b = profile.brain {
            let service = b.service.flatMap { id in prefs.ai.services.first { $0.id == id } }
            let own = b.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = own.isEmpty ? (service?.model ?? "") : own
            if service != nil || !model.isEmpty {
                brain = KitBrain(model: model, serviceName: service.map(\.label),
                                 baseURL: service.map { MCPServerConfig.withoutSecrets(url: $0.baseURL.trimmingCharacters(in: .whitespaces)) })
            }
        }
        let known = Set(prefs.mcpServers.map(\.id))
        self.init(name: profile.name, hue: profile.hue, favoriteHue: profile.favoriteHue, scale: profile.scale,
                  personality: profile.personality, instructions: profile.instructions, brain: brain, usesShell: profile.usesShell,
                  tools: Dictionary(uniqueKeysWithValues: ImpToolGroup.allCases.map { ($0, profile.uses($0)) }),
                  exchangesSent: profile.exchangesSent, sendsToolCalls: profile.remembersToolCalls,
                  servers: profile.servers.filter(known.contains),
                  triggers: prefs.shortcuts(of: profile.id).map { var s = $0; s.performer = nil; return s },
                  chats: chats.filter { $0.peer == nil && !$0.isEmpty })
        traits = profile.traits
        animations = profile.animations
    }

    /// Whether it may use a group of its own tools: what the kit says, else what a new Imp has.
    public func uses(_ group: ImpToolGroup) -> Bool { tools[group] ?? group.isOnByDefault }

    public var toolsOn: [ImpToolGroup] { ImpToolGroup.allCases.filter(uses) }

    /// A colour for the favourite when a file doesn't say (it's a secret anyway).
    static func otherHue(than hue: Double) -> Double { (hue + 0.5).truncatingRemainder(dividingBy: 1) }

    // MARK: Reading

    /// One entry of `imps`. `names` maps the kit's server names to their ids. What can't be read goes to
    /// `problems` (for the "Skipped" list); nil when the entry can't be used at all.
    static func read(_ json: JSONValue, servers names: [String: UUID], problems: inout [String]) -> KitImp? {
        guard case .object = json else { problems.append(String(localized: "Should be an object.")); return nil }
        guard let name = json["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            problems.append(String(localized: "Needs a name.")); return nil
        }
        let hue = json["hue"]?.double.map { min(max($0, 0), 1) } ?? ImpProfile.defaultHue
        var imp = KitImp(name: name, hue: hue, favoriteHue: json["favoriteHue"]?.double.map { min(max($0, 0), 1) },
                         scale: json["scale"]?.double.map { min(max($0, 0.5), 2) } ?? 1,
                         personality: json["personality"]?.string ?? "",
                         instructions: json["instructions"]?.string,
                         usesShell: json["shell"]?.bool ?? true,
                         exchangesSent: json["exchangesSent"]?.int.map { min(max($0, 1), ChatMemory.storedExchanges) },
                         sendsToolCalls: json["sendsToolCalls"]?.bool ?? true)
        if let brain = json["brain"], case .object = brain {
            let model = brain["model"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = brain["service"]?["baseURL"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let service = brain["service"]?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !model.isEmpty || !url.isEmpty {
                imp.brain = KitBrain(model: model, serviceName: url.isEmpty ? nil : (service.isEmpty ? nil : service), baseURL: url.isEmpty ? nil : url)
            }
        }
        if case .object(let groups)? = json["tools"] {
            for group in ImpToolGroup.allCases { if let on = groups[group.rawValue]?.bool { imp.tools[group] = on } }
        }
        if let list = json["mcpServers"]?.array {
            for case .string(let key) in list {
                if let id = names[key] { if !imp.servers.contains(id) { imp.servers.append(id) } }
                else { problems.append(String(localized: "Uses the tool “\(key)”, which isn't in the kit.")) }
            }
        }
        if let list = json["triggers"]?.array {
            for (i, item) in list.enumerated() {
                do {
                    var shortcut = try Shortcut(tool: item, imp: UUID())
                    shortcut.performer = nil
                    imp.triggers.append(shortcut)
                } catch {
                    problems.append(String(localized: "Trigger \(i + 1): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"))
                }
            }
        }
        if let list = json["chats"]?.array {
            imp.chats = list.compactMap { Chat(kit: $0) }
        }
        if let traits = json["traits"], case .object = traits { imp.traits = ImpTraits(kit: traits) }
        if let list = json["animations"]?.array { imp.animations = MadeAnimation.read(list, problems: &problems) }
        return imp
    }

    // MARK: Writing

    /// `keys` names the kit's servers, as written in its `mcpServers`.
    func kitJSON(serverKeys keys: [UUID: String]) -> JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "hue": .number(hue), "favoriteHue": .number(favoriteHue), "scale": .number(scale),
            "personality": .string(personality), "shell": .bool(usesShell),
            "tools": .object(Dictionary(uniqueKeysWithValues: ImpToolGroup.allCases.map { ($0.rawValue, JSONValue.bool(uses($0))) })),
            "sendsToolCalls": .bool(sendsToolCalls),
        ]
        if let instructions { o["instructions"] = .string(instructions) }
        if let exchangesSent { o["exchangesSent"] = .number(Double(exchangesSent)) }
        if let brain { o["brain"] = brain.kitJSON }
        let used = servers.compactMap { keys[$0] }
        if !used.isEmpty { o["mcpServers"] = .array(used.map { .string($0) }) }
        if !triggers.isEmpty { o["triggers"] = .array(triggers.map(\.kitJSON)) }
        if !chats.isEmpty { o["chats"] = .array(chats.map(\.kitJSON)) }
        if !traits.isPlain { o["traits"] = traits.kitJSON }
        if !animations.isEmpty { o["animations"] = .array(animations.map(\.kitJSON)) }
        return .object(o)
    }
}

/// Which model an Imp thinks with, by what's the same on every Mac: the model's name and the
/// service's address (never a local id, never a key).
public struct KitBrain: Equatable, Sendable {
    /// Empty: whatever the service's own model is.
    public var model: String
    public var serviceName: String?
    /// Nil: the receiver's default service.
    public var baseURL: String?

    public init(model: String = "", serviceName: String? = nil, baseURL: String? = nil) {
        self.model = model; self.serviceName = serviceName; self.baseURL = baseURL
    }

    var kitJSON: JSONValue {
        var o: [String: JSONValue] = [:]
        if !model.isEmpty { o["model"] = .string(model) }
        if let baseURL {
            var s: [String: JSONValue] = ["baseURL": .string(baseURL)]
            if let serviceName { s["name"] = .string(serviceName) }
            o["service"] = .object(s)
        }
        return .object(o)
    }

    /// "gpt-4o on OpenAI", for a sentence.
    public var summary: String {
        let service = serviceName ?? baseURL.flatMap { URL(string: $0)?.host } ?? baseURL
        switch (model.isEmpty, service) {
        case (false, let s?): return "\(model) on \(s)"
        case (false, nil): return model
        case (true, let s?): return s
        case (true, nil): return ""
        }
    }
}

extension AIConfig {
    /// The service at this address (case, spaces and a trailing slash don't matter).
    public func service(atAddress address: String) -> Service? {
        let wanted = Self.normalized(address)
        guard !wanted.isEmpty else { return nil }
        return services.first { Self.normalized($0.baseURL) == wanted }
    }

    static func normalized(_ address: String) -> String {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Chats

private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func kitDate(_ json: JSONValue?) -> Date? { json?.string.flatMap { ISO8601DateFormatter().date(from: $0) } }

extension Chat {
    /// A chat as it's written in a kit: what the chat shows and what the Imp remembers of it.
    var kitJSON: JSONValue {
        var memory: [String: JSONValue] = ["messages": .array(self.memory.messages.map(\.kitJSON))]
        if let recap = self.memory.recap { memory["recap"] = .string(recap) }
        return .object(["title": .string(title), "created": .string(iso(created)), "updated": .string(iso(updated)),
                        "turns": .array(turns.map(\.kitJSON)), "memory": .object(memory)])
    }

    /// A chat from a kit, as a new one (fresh ids), cut to what the app keeps. Nil when there's nothing in it.
    init?(kit json: JSONValue) {
        guard case .object = json else { return nil }
        let turns = (json["turns"]?.array ?? []).compactMap { ChatTurn(kit: $0) }.suffix(ChatHistory.limit)
        var memory = ChatMemory()
        if let messages = json["memory"]?["messages"]?.array {
            memory.remember(messages.compactMap { ChatMessage(kit: $0) })      // clips, drops pictures, caps the length
        }
        let recap = json["memory"]?["recap"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        memory = ChatMemory(messages: memory.messages, recap: recap?.isEmpty == false ? recap : nil)
        guard !turns.isEmpty || !memory.isEmpty else { return nil }
        let first = turns.first?.date ?? Date()
        var chat = Chat(title: json["title"]?.string ?? "", created: kitDate(json["created"]) ?? first, turns: Array(turns), memory: memory)
        if chat.title.trimmingCharacters(in: .whitespaces).isEmpty, let t = turns.first(where: { $0.via != .recap }) { chat.title = Chat.title(for: t) }
        if let updated = kitDate(json["updated"]) { chat.updated = updated }
        self = chat
    }
}

extension ChatTurn {
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["date": .string(iso(date)), "request": .string(request), "reply": .string(reply)]
        if failed { o["failed"] = .bool(true) }
        if let via { o["via"] = .string(via.rawValue) }
        if let instruction { o["instruction"] = .string(instruction) }
        if let copiedText { o["copiedText"] = .string(copiedText) }
        if let sender { o["sender"] = .object(["name": .string(sender.name), "hue": .number(sender.hue)]) }
        if !steps.isEmpty {
            o["steps"] = .array(steps.map { step in
                var s: [String: JSONValue] = ["icon": .string(step.icon), "title": .string(step.title), "request": .string(step.request)]
                if let response = step.response { s["response"] = .string(response) }
                if step.failed { s["failed"] = .bool(true) }
                return .object(s)
            })
        }
        return .object(o)
    }

    init?(kit json: JSONValue) {
        guard case .object = json, let request = json["request"]?.string else { return nil }
        let steps = (json["steps"]?.array ?? []).map { s in
            Step(icon: s["icon"]?.string ?? "hammer", title: s["title"]?.string ?? "", request: s["request"]?.string ?? "",
                 response: s["response"]?.string, failed: s["failed"]?.bool ?? false)
        }
        var sender: Sender?
        if let name = json["sender"]?["name"]?.string { sender = Sender(id: UUID(), name: name, hue: json["sender"]?["hue"]?.double ?? 0) }
        self.init(date: kitDate(json["date"]) ?? Date(), request: request, reply: json["reply"]?.string ?? "",
                  failed: json["failed"]?.bool ?? false, steps: steps, via: json["via"]?.string.flatMap(Via.init(rawValue:)),
                  instruction: json["instruction"]?.string, copiedText: json["copiedText"]?.string, sender: sender)
    }
}

extension ChatMessage {
    var kitJSON: JSONValue {
        var o: [String: JSONValue] = ["role": .string(role)]
        if let content { o["content"] = .string(content) }
        if let toolCalls, !toolCalls.isEmpty {
            o["toolCalls"] = .array(toolCalls.map { .object(["id": .string($0.id), "name": .string($0.name), "arguments": .string($0.arguments)]) })
        }
        if let toolCallID { o["toolCallID"] = .string(toolCallID) }
        return .object(o)
    }

    init?(kit json: JSONValue) {
        guard let role = json["role"]?.string, ["user", "assistant", "tool", "system"].contains(role) else { return nil }
        let calls: [ToolCall] = (json["toolCalls"]?.array ?? []).compactMap { c in
            guard let name = c["name"]?.string else { return nil }
            return ToolCall(id: c["id"]?.string ?? UUID().uuidString, name: name, arguments: c["arguments"]?.string ?? "{}")
        }
        self.init(role: role, content: json["content"]?.string, toolCalls: calls.isEmpty ? nil : calls, toolCallID: json["toolCallID"]?.string)
    }
}

extension JSONValue {
    var double: Double? { if case .number(let n) = self { return n } else { return nil } }
}

// MARK: - Adding to the settings

extension ImpProfile {
    /// `name` if no Imp of the troupe has it, else "Pip 2", "Pip 3"…
    public static func uniqueName(_ name: String, avoiding used: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return randomName(avoiding: used) }
        let lower = Set(used.map { $0.lowercased() })
        var candidate = base, n = 2
        while lower.contains(candidate.lowercased()) { candidate = "\(base) \(n)"; n += 1 }
        return candidate
    }
}

extension ImpPreferences {
    /// What `add` made of one Imp of a kit.
    public struct ImportedImp: Equatable, Sendable {
        public var id: UUID
        public var name: String
        /// Chats to put in its history before it appears (`ChatHistory.adopt`), oldest first.
        public var chats: [Chat]
    }

    /// A new Imp from a kit's: a new id and a name nobody has, waiting at home (not activated), its
    /// models matched to a service by address (never added), its triggers and tools its own.
    /// Whether `kit.servers` entries are in the library is `add`'s business; this takes the ids they ended up with.
    mutating func hatch(_ source: KitImp, servers serverIDs: [UUID: UUID], withChats: Bool) -> ImportedImp {
        var p = ImpProfile(name: ImpProfile.uniqueName(source.name, avoiding: imps.map(\.name)), hue: source.hue,
                           favoriteHue: source.favoriteHue, scale: source.scale, personality: source.personality)
        p.isActive = false
        p.traits = source.traits
        p.animations = source.animations.map { var a = $0; a.id = UUID(); return a }
        p.instructions = source.instructions
        p.usesShell = source.usesShell
        for group in ImpToolGroup.allCases { p.setUses(group, source.uses(group)) }
        p.exchangesSent = source.exchangesSent
        p.sendsToolCalls = source.sendsToolCalls ? nil : false
        if let b = source.brain {
            if let address = b.baseURL {
                if let service = ai.service(atAddress: address) {
                    p.brain = Brain(service: service.id, model: b.model == service.model ? "" : b.model)
                }
            } else if !b.model.isEmpty {
                p.brain = Brain(service: nil, model: b.model)
            }
        }
        for id in source.servers {
            if let mine = serverIDs[id], !p.servers.contains(mine) { p.servers.append(mine) }
        }
        imps.append(p)
        for var trigger in source.triggers {
            trigger.id = UUID()
            trigger.performer = p.id
            shortcuts.append(trigger)
        }
        let chats = withChats ? source.chats.sorted { $0.updated < $1.updated } : []
        return ImportedImp(id: p.id, name: p.name, chats: chats)
    }
}

// MARK: - Exporting

extension Kit {
    /// The Imps `ids` (in the troupe's order) with their triggers, the tools they use and, when `chats`
    /// has any for them, their chats. `shared` adds the triggers every Imp answers to (the click triggers
    /// every install starts with are left out unless the user changed them).
    public static func exporting(imps ids: Set<UUID>, from prefs: ImpPreferences, name: String = "", shared: Bool = false,
                                 chats: [UUID: [Chat]] = [:]) -> Kit {
        var kit = Kit(name: name)
        kit.imps = prefs.imps.filter { ids.contains($0.id) }.map { KitImp($0, in: prefs, chats: chats[$0.id] ?? []) }
        let used = Set(kit.imps.flatMap(\.servers))
        kit.servers = prefs.mcpServers.filter { used.contains($0.id) }
        if shared {
            let stock = ImpPreferences().shortcuts
            kit.triggers = prefs.sharedShortcuts.filter { s in
                !stock.contains { $0.id == s.id && $0.name == s.name && $0.trigger == s.trigger && $0.command == s.command
                    && $0.prompt == s.prompt && $0.conditions == s.conditions }
            }
        }
        return kit
    }
}
