import Foundation

// Moving home. The phone sends a kit with one Imp (its chats, personality, looks, brain and HTTP
// tools, no secrets) and the secrets next to it. The Mac reads it with the real kit parser and
// takes it in as an ordinary Mac Imp.

extension PocketImp {
    /// The request that moves this Imp to the Mac, thrown off `exit` at `height`. Secrets are read
    /// from `secrets` into the request, never into the kit. Oldest chats and turns are dropped until
    /// it fits a frame (`LinkProtocol.maxFrame`).
    public func adoption(secrets store: PocketSecrets, exit: LinkSide, height: Double, speed: Double) throws -> LinkRequest {
        try validateAsMove()
        var imp = self
        while true {
            let (kit, secrets) = imp.handover(store)
            let request = LinkRequest.adopt(imp: id, kit: kit, secrets: secrets, exit: exit, height: height, speed: speed)
            do {
                _ = try LinkFrame.encode(request)
                return request
            } catch LinkFrame.Failure.tooBig {
                guard imp.shrink() else { throw PocketError.tooBig }
            }
        }
    }

    /// The kit with this Imp in it and the secrets that go with it, named as the kit names its servers.
    func handover(_ store: PocketSecrets) -> (kit: String, secrets: LinkSecrets) {
        var kit = Kit()
        var imp = KitImp(name: name.trimmingCharacters(in: .whitespacesAndNewlines), hue: hue, scale: scale, personality: personality,
                         brain: KitBrain(model: brain.model, serviceName: URL(string: brain.baseURL)?.host, baseURL: brain.baseURL),
                         chats: chats.filter { $0.peer == nil && !$0.isEmpty })
        imp.traits = traits
        kit.servers = servers.map {
            var config = MCPServerConfig(name: $0.name, transport: .http, url: $0.url)
            config.id = $0.id
            if let header = $0.header { config.headers = [header: ""] }
            return config
        }
        imp.servers = kit.servers.map(\.id)
        kit.imps = [imp]
        var secrets = LinkSecrets(apiKey: store.get(.apiKey, imp: id).flatMap { $0.isEmpty ? nil : $0 })
        let keys = kit.serverKeys
        for server in servers {
            guard let header = server.header, let key = keys[server.id],
                  let value = store.get(.header(server.id), imp: id), !value.isEmpty else { continue }
            secrets.headers[key] = [header: value]
        }
        return (kit.json(pretty: false), secrets)
    }

    /// Drops the oldest of what it carries: a chat, or when only one is left, the older half of its turns.
    private mutating func shrink() -> Bool {
        let carried = chats.indices.filter { chats[$0].peer == nil && !chats[$0].isEmpty }
        guard let first = carried.first else { return false }
        if carried.count > 1 {
            chats.remove(at: first)
            return true
        }
        var chat = chats[first]
        let exchanges = ChatMemory.exchanges(in: chat.memory.messages)
        guard chat.turns.count > 1 || exchanges.count > 1 else {
            chats.remove(at: first)
            return true
        }
        chat.turns = Array(chat.turns.suffix(chat.turns.count / 2))
        chat.memory = ChatMemory(messages: exchanges.suffix(exchanges.count / 2).flatMap { $0 }, recap: chat.memory.recap)
        chats[first] = chat
        return true
    }
}

// MARK: - On the Mac

extension ImpPreferences {
    /// What taking a pocket Imp in did.
    public struct Adoption: Equatable, Sendable {
        /// The Imp: it keeps the id it had on the phone. Chats go in its history (`ChatHistory.adopt`) before it appears.
        public var imp: ImportedImp
        /// The service it thinks with, found by its address or added.
        public var service: UUID?
        /// The key that came with it, for the app to save for `service` if that has none yet.
        public var apiKey: String?
    }

    /// Takes in the Imp of a pocket Imp's kit, as a new Imp that keeps `id`, waiting at home (not
    /// activated). Whatever the kit says beyond what a pocket Imp has (tools, triggers, animations,
    /// programs to run) is ignored or refused: the Imp gets what a freshly hatched one has. Its
    /// service is found by address or added, and so are its servers, which only reuse one already
    /// in the library when it has the same address. Throws if `id` is already an Imp here.
    public mutating func adopt(kit text: String, as id: UUID, secrets: LinkSecrets) throws -> Adoption {
        let parsed = try Kit.parse(text, limit: LinkProtocol.maxFrame)
        guard parsed.imps.count == 1, parsed.triggers.isEmpty, parsed.animations.isEmpty, var source = parsed.imps.first else {
            throw PocketError.notOnePocketImp
        }
        guard !imps.contains(where: { $0.id == id }) else { throw PocketError.alreadyHere }
        guard source.name.count <= PocketImp.maxName, parsed.servers.count <= PocketImp.maxServers else { throw PocketError.tooBig }
        if let address = source.brain?.baseURL { try PocketImp.check(url: address) }
        var kit = parsed
        let keys = kit.serverKeys
        for i in kit.servers.indices {
            guard kit.servers[i].transport == .http else { throw PocketError.notOnePocketImp }
            try PocketImp.check(url: kit.servers[i].url)
            let given = secrets.headers[keys[kit.servers[i].id] ?? ""] ?? [:]
            for name in kit.servers[i].headers.keys { kit.servers[i].headers[name] = given[name] ?? "" }
        }
        source.triggers = []
        source.animations = []
        source.tools = [:]
        source.usesShell = true
        source.instructions = nil
        source.exchangesSent = nil
        source.sendsToolCalls = true
        kit.imps = [source]

        if let brain = source.brain, let address = brain.baseURL, ai.service(atAddress: address) == nil {
            ai.add(Service(name: brain.serviceName ?? "", baseURL: address, model: brain.model))
        }
        let added = add(kit, imps: [source.id], triggers: [], servers: [], for: nil)
        guard var imported = added.imps.first, let i = imps.firstIndex(where: { $0.id == imported.id }) else { throw PocketError.notOnePocketImp }
        imps[i].id = id
        imported.id = id
        let key = secrets.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Adoption(imp: imported, service: imps[i].brain?.service, apiKey: key?.isEmpty == false ? key : nil)
    }
}
