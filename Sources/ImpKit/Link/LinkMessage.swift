import Foundation

// Imp Link 2: how devices talk (see `docs/LINK.md`). Every Imp thinks at its home; its body can be on
// any linked device. Messages are JSON, one per frame (`LinkFrame`), over TLS (`LinkChannel`),
// whether the bytes came over Wi-Fi or through the Hop.

/// The protocol's constants and limits. Each side says its own version in `hello`/`welcome`; a side
/// ignores message types it doesn't know, so newer peers can add some without breaking older ones.
public enum LinkProtocol {
    public static let version = 2
    /// Bonjour service type devices advertise.
    public static let serviceType = "_imp-link._tcp"
    /// A device listens here when it can, so another can reach it by address (another network, a VPN).
    public static let port: UInt16 = 47_824
    /// Frames bigger than this are refused (chats are sent a page at a time).
    public static let maxFrame = 4 << 20
    /// Each side pings this often (seconds).
    public static let pingInterval: TimeInterval = 20
    /// A connection that hasn't heard a thing for this long (seconds) is dead: both sides close it.
    public static let silenceLimit: TimeInterval = 45
    /// A visitor without a valid claim is closed after this long (seconds).
    public static let visitorGrace: TimeInterval = 15
    /// A thrown Imp that isn't answered in this time (seconds) bounces back.
    public static let transferTimeout: TimeInterval = 10
    /// A message between Imps that isn't answered in this time (seconds) fails.
    public static let answerTimeout: TimeInterval = 120
    /// An invite works this long (seconds) after its code was last on screen.
    public static let inviteLife: TimeInterval = 15 * 60
    public static let maxLinks = 16
    public static let maxVisits = 24
    public static let maxConnections = 32
    public static let maxText = 20_000
}

/// A side of a screen an Imp is thrown off, or flies in from.
public enum LinkSide: String, Codable, Sendable, Equatable {
    case left, right

    /// Thrown off one side of a screen, it flies in from the other side of the next one.
    public var opposite: LinkSide { self == .left ? .right : .left }
}

/// How an Imp flies onto a screen.
public struct LinkEntry: Codable, Sendable, Equatable {
    /// The side it comes in from.
    public var side: LinkSide
    /// How far down that side: 0 the top, 1 the bottom.
    public var height: Double
    /// How hard it was thrown, points a second (0: gently, from a menu).
    public var speed: Double

    public init(side: LinkSide, height: Double, speed: Double) {
        self.side = side
        self.height = min(max(height.isFinite ? height : 0.5, 0), 1)
        self.speed = max(speed.isFinite ? speed : 0, 0)
    }

    /// From the network: out-of-range numbers are brought into range.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(side: try c.decode(LinkSide.self, forKey: .side), height: try c.decode(Double.self, forKey: .height),
                  speed: try c.decode(Double.self, forKey: .speed))
    }

    /// Where it enters after being thrown off `exit` at `height` (it carries on the way it went).
    public static func after(exit: LinkSide, height: Double, speed: Double) -> LinkEntry {
        LinkEntry(side: exit.opposite, height: height, speed: speed)
    }
}

/// What a device needs to draw an Imp exactly as its home does.
public struct LinkImp: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var hue: Double
    public var scale: Double
    public var traits: ImpTraits

    public init(id: UUID, name: String, hue: Double, scale: Double, traits: ImpTraits) {
        self.id = id; self.name = name; self.hue = hue; self.scale = scale; self.traits = traits
    }

    public init(_ profile: ImpProfile) {
        self.init(id: profile.id, name: profile.name, hue: profile.hue, scale: profile.scale, traits: profile.traits)
    }
}

/// An Imp on someone's screen, and the device it thinks on.
public struct LinkStaged: Codable, Sendable, Equatable, Identifiable {
    public var imp: LinkImp
    public var home: UUID

    public init(imp: LinkImp, home: UUID) { self.imp = imp; self.home = home }

    public var id: UUID { imp.id }
}

/// One line of a chat, as a holder shows it.
public struct LinkTurn: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    /// What was asked (by you, a trigger or another Imp).
    public var request: String
    /// Another Imp asked, not you: its name.
    public var from: String?
    public var reply: String
    public var failed: Bool
    /// What the Imp did on the way (tool steps), as short titles.
    public var steps: [String]

    public init(id: UUID, date: Date, request: String, from: String? = nil, reply: String, failed: Bool, steps: [String] = []) {
        self.id = id; self.date = date; self.request = request; self.from = from
        self.reply = reply; self.failed = failed; self.steps = steps
    }

    public init(_ turn: ChatTurn) {
        self.init(id: turn.id, date: turn.date, request: turn.request, from: turn.sender?.name, reply: turn.reply,
                  failed: turn.failed, steps: turn.steps.map(\.title))
    }
}

/// What an Imp is doing right now, while it works on something.
public struct LinkWork: Codable, Sendable, Equatable {
    /// The request it's working on.
    public var request: String
    /// What it's doing (the current step), if anything.
    public var status: String?
    /// The answer so far, as it streams in.
    public var partial: String
    /// Another Imp asked, not you: its name. (It shows as a speech bubble, not in your chat.)
    public var from: String?

    public init(request: String, status: String?, partial: String, from: String? = nil) {
        self.request = request; self.status = status; self.partial = partial; self.from = from
    }
}

/// An Imp talking with another Imp (`imp_message`), as its speech bubble shows it: asked by one,
/// answering it, or waiting for another's answer.
public struct LinkSpeech: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        /// Another Imp asked this one something; it's thinking.
        case asked
        /// This Imp's answer to that question.
        case reply
        /// This Imp asked another one and waits for the answer.
        case asking
    }
    public var id: UUID
    public var role: Role
    /// The other Imp, with its colour.
    public var peer: String
    public var hue: Double
    public var question: String
    /// The answer (`reply`), so far if it's still streaming.
    public var text: String

    public init(id: UUID, role: Role, peer: String, hue: Double, question: String, text: String = "") {
        self.id = id; self.role = role; self.peer = peer; self.hue = hue; self.question = question; self.text = text
    }
}

/// A piece of a file a holder asked for (`LinkMessage.file`), in order.
public struct LinkFilePart: Codable, Sendable, Equatable {
    /// The file's name, for showing and for its type.
    public var name: String
    /// The whole file's size in bytes.
    public var size: Int
    public var offset: Int
    public var data: Data

    public init(name: String, size: Int, offset: Int, data: Data) {
        self.name = name; self.size = size; self.offset = offset; self.data = data
    }

    public var isLast: Bool { offset + data.count >= size }

    /// Bytes per part: small enough to keep frames light, big enough to move a video quickly.
    public static let chunk = 256 * 1024
    /// The biggest file a holder may fetch.
    public static let maxSize = 512 * 1024 * 1024
}

/// The secrets of a pocket Imp that moves to a Mac: they travel apart from its kit, which never
/// holds any. Never log it.
public struct LinkSecrets: Codable, Sendable, Equatable {
    /// The key of its service, if it has one.
    public var apiKey: String?
    /// Header values by the name its servers have in the kit, then by header name.
    public var headers: [String: [String: String]]

    public init(apiKey: String? = nil, headers: [String: [String: String]] = [:]) {
        self.apiKey = apiKey; self.headers = headers
    }
}

/// What you did to an Imp on a screen.
public enum LinkFeeling: String, Codable, Sendable {
    case poke, cuddle, shake, drop
}

/// Why a thrown Imp bounces back.
public enum LinkDecline: String, Codable, Sendable, Equatable {
    /// No room for another Imp.
    case full
    /// Playing a game.
    case playing
    /// Not linked, or not allowed.
    case notLinked
    /// No answer in time (made up by the thrower, never sent).
    case timeout
    /// The receiver's user said no, or something else.
    case other

    /// A reason a newer version made up is still a no.
    public init(from decoder: Decoder) throws {
        self = LinkDecline(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

/// Both directions share this one enum: every device is a host to some and a guest to others, and
/// either side can send any message. What a device does with one depends on who sent it (see
/// `LinkAccess`). Messages this version doesn't know decode to nil and are ignored. `imp` is always
/// the Imp's id.
public enum LinkMessage: Codable, Sendable, Equatable {
    // MARK: Connection

    /// First message on a connection, guest to host: who's calling, signed for this connection.
    case hello(device: UUID, name: String, kind: LinkKind, key: Data, version: Int, proof: Data, join: Data?)
    /// The host's answer: who it is, whether the guest is a linked peer, signed for this connection.
    case welcome(device: UUID, name: String, kind: LinkKind, version: Int, linked: Bool, proof: Data)
    /// Still there (sent regularly, so a dead connection is noticed).
    case ping
    case pong
    /// This device is closing the connection on purpose; `reason` is for people.
    case bye(reason: String)
    /// Where this device can be reached (its door key opens its TLS); sent after a handshake and
    /// whenever its addresses or its server change.
    case routes(door: Data, routes: LinkRoutes)
    /// The Imps on this device's screen right now (sent whenever they change).
    case stage(imps: [LinkStaged])

    // MARK: Throwing

    /// An Imp flies onto the receiver's screen. Unless the receiver is its home, the home's card and
    /// the Imp's ticket come with it.
    case pass(transfer: UUID, imp: LinkImp, entry: LinkEntry, home: LinkCard?, ticket: Data?)
    case took(transfer: UUID)
    /// The Imp bounces back.
    case declined(transfer: UUID, reason: LinkDecline)
    /// A holder asks its Imp's home to recognise it as the holder, with the ticket it has.
    case claim(imp: UUID, ticket: Data)
    /// The home's answer to a good claim: the new ticket (the old one is dead).
    case claimed(imp: UUID, ticket: Data)
    /// The receiver is not this Imp's holder (any more): its body there has to go.
    case gone(imp: UUID)
    /// Sends a visiting Imp home from wherever it is.
    case release(imp: UUID, ticket: Data)

    // MARK: A holder asks an Imp's home

    /// A message for the Imp, typed into its chat.
    case ask(imp: UUID, text: String)
    /// Stop what it's working on.
    case stop(imp: UUID)
    /// Start a fresh chat.
    case newChat(imp: UUID)
    /// Patted, spun or shaken: the home plays the animation that answers to it.
    case felt(imp: UUID, feeling: LinkFeeling)
    /// A file a reply shows or links to (a picture, a voice, a video, a document), as written in
    /// the reply: a path on the home, relative to the Imp's folder or absolute. The home sends it
    /// back in parts (`filePart`), or says why not (`fileFailed`). `id` names the transfer.
    case file(id: UUID, imp: UUID, ref: String)
    /// Asks for what the Imp said with other Imps, as far as the home's chats know.
    case talks(imp: UUID)

    // MARK: A home tells the holder

    /// Looks changed (colour, size, character).
    case look(imp: LinkImp)
    /// The latest turns of the Imp's current chat, oldest first.
    case chat(imp: UUID, turns: [LinkTurn])
    /// What it's working on (nil: nothing).
    case work(imp: UUID, work: LinkWork?)
    /// Its mood changed (a `Mood` raw value).
    case mood(imp: UUID, mood: String)
    /// Whether it has a brain it can think with at home (a service, a model and, where one is
    /// needed, a key). Sent with everything else to a new holder and whenever it changes. Without
    /// one it sleeps wherever its body is (`Wakefulness`), and asking it is refused there at once.
    case brain(imp: UUID, ready: Bool)
    /// Plays an animation, beat by beat.
    case animate(imp: UUID, beats: [AnimationBeat])
    /// What it's saying to another Imp right now (nil: nothing).
    case speech(imp: UUID, speech: LinkSpeech?)
    /// A part of a file the holder asked for.
    case filePart(id: UUID, part: LinkFilePart)
    /// The file can't be sent: why.
    case fileFailed(id: UUID, reason: String)
    /// The answer to `talks`: every exchange in the home's chats that the Imp asked or answered
    /// (`TalkLog.forLink`).
    case talkLines(imp: UUID, lines: [TalkLine])

    // MARK: Imps talking

    /// An Imp asks another something (`imp_message`). `toHome` is the target's home, which
    /// answers; a device that isn't it forwards the question there once (`forwarded`).
    case message(id: UUID, from: LinkImp, to: UUID, toHome: UUID, text: String, forwarded: Bool)
    /// The reply to a `message`: what the Imp said, or why it couldn't (`failed`).
    case answer(id: UUID, text: String, failed: Bool)

    // MARK: Moving in for good

    /// An Imp hatched here moves to the receiver for good: `kit` is its kit (`PocketImp.adoption`).
    /// The receiver answers `adopted` once its user agreed, or `declined`; the sender deletes its
    /// copy only after `adopted`.
    case adopt(transfer: UUID, imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry)
    case adopted(transfer: UUID)
}

extension LinkMessage {
    /// Whether the sizes and counts in a message from the network are sane. The node drops a
    /// message that isn't; the frame limit already bounds everything else.
    public var isSound: Bool {
        func name(_ s: String) -> Bool { s.count <= LinkDevice.longestName * 2 }
        func text(_ s: String) -> Bool { s.count <= LinkProtocol.maxText }
        func key(_ d: Data) -> Bool { d.count == LinkCrypto.keyBytes }
        func imp(_ i: LinkImp) -> Bool { name(i.name) }
        switch self {
        case .hello(_, let n, _, let k, _, let proof, let join):
            return name(n) && key(k) && proof.count == Hop.proofBytes && (join.map(key) ?? true)
        case .welcome(_, let n, _, _, _, let proof): return name(n) && proof.count == Hop.proofBytes
        case .bye(let reason): return reason.count <= 200
        case .routes(let door, _): return key(door)
        case .stage(let imps): return imps.count <= 64 && imps.allSatisfy { imp($0.imp) }
        case .pass(_, let i, _, let home, let ticket):
            return imp(i) && (ticket.map(key) ?? true) && (home == nil) == (ticket == nil) && (home.map { name($0.device.name) } ?? true)
        case .claim(_, let t), .claimed(_, let t), .release(_, let t): return key(t)
        case .ask(_, let t): return text(t)
        case .file(_, _, let ref): return ref.count <= 4_096
        case .look(let i): return imp(i)
        case .chat(_, let turns): return turns.count <= 500 && turns.allSatisfy { $0.steps.count <= 200 }
        case .mood(_, let m): return m.count <= 40
        case .animate(_, let beats): return beats.count <= 256
        case .filePart(_, let p):
            return p.data.count <= 1 << 20 && p.size >= 0 && p.size <= LinkFilePart.maxSize && p.offset >= 0 && p.offset <= p.size && name(p.name)
        case .fileFailed(_, let reason): return reason.count <= 500
        case .talkLines(_, let lines): return lines.count <= 300
        case .message(_, let from, _, _, let t, _): return imp(from) && text(t)
        case .answer(_, let t, _): return text(t)
        case .adopt(_, _, let kit, _, _): return kit.utf8.count <= LinkProtocol.maxFrame
        case .ping, .pong, .gone, .stop, .newChat, .felt, .talks, .work, .brain, .speech, .took, .declined, .adopted: return true
        }
    }
}

/// Length-prefixed frames: a 4-byte big-endian length, then that many bytes of JSON.
public struct LinkFrame: Sendable {
    private var buffer = Data()

    public init() {}

    public enum Failure: Error, Equatable { case tooBig(Int) }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder.link.encode(value)
        guard body.count <= LinkProtocol.maxFrame else { throw Failure.tooBig(body.count) }
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Adds bytes as they arrive; returns every complete frame's body. Throws when a frame says
    /// it's bigger than any frame may be (a broken or hostile peer: drop the connection).
    public mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= LinkProtocol.maxFrame else { throw Failure.tooBig(length) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return frames
    }

    /// Decodes a frame's body. Nil for anything this version doesn't understand.
    public static func decode<T: Decodable>(_ type: T.Type, _ body: Data) -> T? {
        try? JSONDecoder.link.decode(type, from: body)
    }
}

extension JSONEncoder {
    static var link: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var link: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
