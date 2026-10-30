import Foundation

// Pocket Imps: Imps hatched on the iPhone. An Imp lives where its brain runs. A pocket Imp thinks on
// the phone, with an OpenAI-compatible service and, if it likes, tools from HTTP MCP servers. It has
// no shell, no computer control, no triggers and none of the Mac's senses. Nothing about it is kept
// in step with the Mac. It can move home once: tossed off the phone while the Mac is connected, it
// becomes an ordinary Mac Imp (`PocketHandover`), and never a pocket Imp again.

/// Where a pocket Imp's brain is: an OpenAI-compatible service and one of its models. The API key is a
/// secret and lives apart (`PocketSecrets`).
public struct PocketService: Codable, Equatable, Sendable {
    public var baseURL: String
    public var model: String

    public init(baseURL: String = "", model: String = "") {
        self.baseURL = baseURL; self.model = model
    }
}

/// A tool server a pocket Imp uses, over HTTP. The header (an `Authorization`, say) is named here
/// and its value is a secret (`PocketSecrets`).
public struct PocketServer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Without a password or a query: keys go in the header.
    public var url: String
    /// The name of a header to send with a value from `PocketSecrets`, if the server wants one.
    public var header: String?

    public init(id: UUID = UUID(), name: String, url: String, header: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.header = header
    }
}

/// Why a pocket Imp can't be used or moved.
public enum PocketError: LocalizedError, Equatable, Sendable {
    case badName
    case badURL(String)
    case noBrain
    case notOnePocketImp
    case alreadyHere
    case tooBig

    public var errorDescription: String? {
        switch self {
        case .badName: String(localized: "An Imp needs a name of up to \(PocketImp.maxName) characters.")
        case .badURL(let url): String(localized: "“\(url)” must start with https://. Plain http:// works only for devices on your own network.")
        case .noBrain: String(localized: "This Imp has no service and model to think with yet.")
        case .notOnePocketImp: String(localized: "That isn't one Imp to take in.")
        case .alreadyHere: String(localized: "There's already an Imp like that here.")
        case .tooBig: String(localized: "This Imp is too big to move.")
        }
    }
}

/// An Imp hatched on the iPhone: everything about it except its secrets. Store it as JSON.
public struct PocketImp: Codable, Equatable, Sendable, Identifiable {
    /// Kept when it moves to the Mac.
    public var id: UUID
    public var name: String
    public var hue: Double
    public var scale: Double
    public var traits: ImpTraits
    public var personality: String
    public var brain: PocketService
    public var servers: [PocketServer]
    /// Oldest first. The last chat with you is the one you're in. Talks with other Imps are chats of
    /// their own (`Chat.peer`).
    public internal(set) var chats: [Chat]

    public static let maxName = 40
    public static let maxServers = 10
    public static let maxChats = 30
    public static let maxTurns = 200
    /// Exchanges of the chat it remembers when it thinks.
    public static let exchangesSent = ChatMemory.defaultExchanges

    public init(id: UUID = UUID(), name: String, hue: Double = ImpProfile.defaultHue, scale: Double = 1, traits: ImpTraits = .plain,
                personality: String? = nil, brain: PocketService = PocketService(), servers: [PocketServer] = [], chats: [Chat] = []) {
        self.id = id; self.name = name; self.hue = hue; self.scale = scale; self.traits = traits
        self.personality = personality ?? Persona.pocket(named: name)
        self.brain = brain; self.servers = servers; self.chats = chats
    }

    /// How the phone draws it (and tells the Mac who it is).
    public var look: LinkImp { LinkImp(id: id, name: name, hue: hue, scale: scale, traits: traits) }

    /// Fit to use: a name, https (or a device on your own network) for every address, and a model.
    public func validate() throws {
        try validateAsMove()
        guard !brain.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw PocketError.noBrain }
    }

    /// What moving home needs: `validate` without insisting on a model (the Mac has its own default).
    func validateAsMove() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxName else { throw PocketError.badName }
        try Self.check(url: brain.baseURL)
        guard servers.count <= Self.maxServers else { throw PocketError.tooBig }
        for server in servers { try Self.check(url: server.url) }
    }

    // MARK: Addresses

    /// https anywhere, or http for a device on your own network (this phone, `.local` names, private
    /// addresses). No password, query or fragment in it: keys go in headers.
    public static func check(url: String) throws {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && isLocal(host: host))
        else { throw PocketError.badURL(text) }
    }

    /// `localhost`, a `.local` name, a loopback or private IPv4 address (10/8, 172.16/12, 192.168/16).
    static func isLocal(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        let o = octets.map { $0! }
        return o[0] == 10 || o[0] == 127 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168)
    }

    // MARK: Chats

    /// The chat with you that's open, if there is one.
    public var current: Chat? { chats.last { $0.peer == nil } }

    /// The turns of the chat with you, the latest `limit`, as the phone shows them.
    public func turns(limit: Int = 40) -> [LinkTurn] {
        (current?.turns ?? []).filter { $0.sender == nil }.suffix(limit).map(LinkTurn.init)
    }

    /// What it remembers of its talk with `peer` (another Imp), or of the chat with you.
    func memory(with peer: UUID?) -> ChatMemory {
        chats.last { $0.peer == peer }?.memory ?? ChatMemory()
    }

    /// Starts a fresh chat with you.
    public mutating func newChat() {
        if let i = chats.lastIndex(where: { $0.peer == nil }), chats[i].isEmpty { return }
        chats.append(Chat())
        trim()
    }

    /// Keeps what an ask came to: its turn, and what the Imp remembers of it.
    public mutating func record(_ answer: PocketAnswer) {
        let i = chats.lastIndex { $0.peer == answer.peer } ?? {
            chats.append(Chat(created: answer.turn.date, peer: answer.peer))
            return chats.count - 1
        }()
        if chats[i].turns.isEmpty { chats[i].title = Chat.title(for: answer.turn) }
        chats[i].turns = Array((chats[i].turns + [answer.turn]).suffix(Self.maxTurns))
        if let memory = answer.memory { chats[i].memory = memory }
        chats[i].updated = answer.turn.date
        trim()
    }

    private mutating func trim() {
        if chats.count > Self.maxChats { chats.removeFirst(chats.count - Self.maxChats) }
    }
}

extension Persona {
    /// A starting personality for an Imp hatched on the iPhone.
    public static func pocket(named name: String) -> String {
        """
        You are \(name), one of the tiny imps living in the user's pocket, on their iPhone. You're helpful and brief, \
        one to three sentences unless asked for more, with your own quirky take on things. Reply in the \
        language the user speaks, in plain sentences.
        """
    }
}
