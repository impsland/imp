import Foundation

// Imp Link: how the Mac and an iPhone talk. The Mac keeps every Imp's brain (models, keys, tools,
// chats); an Imp tossed onto the iPhone is the same Imp, just away from the desktop: the phone is
// its body and its chat. Messages are JSON, one per frame (`LinkFrame`), over any reliable,
// authenticated byte stream: today TLS with a pre-shared key on the local network (`LinkChannel`),
// tomorrow the same frames through a relay over the internet.
//
// The phone has Imps of its own too (`PocketImp`): they think on the phone. They reach the Mac only
// to talk to its Imps, and to move home (`adopt`).

/// The protocol's version. Each side says its own in `hello`/`welcome`; a side ignores message
/// types it doesn't know, so newer peers can add some without breaking older ones.
public enum LinkProtocol {
    public static let version = 1
    /// Bonjour service type the Mac advertises.
    public static let serviceType = "_imp-link._tcp"
    /// The Mac listens here too, so a phone can reach it by address (another network, a VPN).
    public static let port: UInt16 = 47_824
    /// Frames bigger than this are refused (chats are sent a page at a time).
    public static let maxFrame = 4 << 20
    /// The phone pings this often (seconds) while it's connected.
    public static let pingInterval: TimeInterval = 20
    /// A link that hasn't heard a thing for this long (seconds) is dead: both sides close it.
    public static let silenceLimit: TimeInterval = 45
}

/// A side of a screen an Imp is tossed off, or flies in from.
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

    /// Where it enters after being thrown off `exit` at `height` (it carries on the way it went).
    public static func after(exit: LinkSide, height: Double, speed: Double) -> LinkEntry {
        LinkEntry(side: exit.opposite, height: height, speed: speed)
    }
}

/// What the phone needs to draw an Imp exactly as the Mac does.
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

/// One line of a chat, as the phone shows it.
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
/// answering it, or waiting for another's answer. The phone shows it above the Imp.
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

/// A piece of a file the phone asked for (`LinkRequest.file`), in order.
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
    /// The biggest file a phone may fetch.
    public static let maxSize = 512 * 1024 * 1024
}

/// The secrets of a pocket Imp that moves to the Mac: they travel apart from its kit, which never
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

/// iPhone → Mac.
public enum LinkRequest: Codable, Sendable, Equatable {
    /// First message on a connection: who's calling.
    case hello(device: UUID, name: String, version: Int)
    /// A message for an Imp on the phone, typed into its chat.
    case ask(imp: UUID, text: String)
    /// Stop what it's working on.
    case stop(imp: UUID)
    /// Start a fresh chat.
    case newChat(imp: UUID)
    /// Thrown off a side of the phone: it flies onto the Mac.
    case toss(imp: UUID, exit: LinkSide, height: Double, speed: Double)
    /// Patted, spun or shaken on the phone: the Mac plays the animation that answers to it.
    case felt(imp: UUID, feeling: LinkFeeling)
    /// A file a reply shows or links to (a picture, a voice, a video, a document), as written in
    /// the reply: a path on the Mac, relative to the Imp's folder or absolute. The Mac sends it
    /// back in parts (`LinkUpdate.file`), or says why not (`fileFailed`). `id` names the transfer.
    case file(id: UUID, imp: UUID, ref: String)
    /// Still there (sent while idle, so a dead connection is noticed).
    case ping
    /// The Imps hatched on the phone, sent after `welcome` and whenever they change. Mac Imps can
    /// message these, and only these may send messages (`message`).
    case troupe([LinkImp])
    /// A pocket Imp moves home: thrown off a side of the phone, it flies onto the Mac as an ordinary
    /// Mac Imp. `kit` is its kit (`PocketImp.adoption`). The Mac answers `adopted`, or `refused` and
    /// the phone keeps it. The phone deletes its copy only after `adopted`.
    case adopt(imp: UUID, kit: String, secrets: LinkSecrets, exit: LinkSide, height: Double, speed: Double)
    /// A pocket Imp asks a Mac Imp something (`imp_message`). The Mac answers with `answer`.
    case message(id: UUID, from: UUID, to: UUID, text: String)
    /// The reply to a Mac Imp's `ask`: what the pocket Imp said, or why it couldn't (`failed`).
    case answered(id: UUID, text: String, failed: Bool)
}

/// Mac → iPhone.
public enum LinkUpdate: Codable, Sendable, Equatable {
    /// Answer to `hello`: this Mac, the Imps on this phone, and the ones on the Mac (to talk about).
    case welcome(mac: String, version: Int, imps: [LinkImp], others: [LinkImp])
    /// An Imp flies onto the phone.
    case arrive(imp: LinkImp, entry: LinkEntry)
    /// An Imp leaves the phone (called back on the Mac). `entry` is nil when it just goes.
    case leave(imp: UUID)
    /// Looks changed (colour, size, character).
    case look(imp: LinkImp)
    /// The Imps out on the Mac changed.
    case others([LinkImp])
    /// The latest turns of an Imp's current chat, oldest first.
    case chat(imp: UUID, turns: [LinkTurn])
    /// What it's working on (nil: nothing).
    case work(imp: UUID, work: LinkWork?)
    /// Its mood changed (a `Mood` raw value).
    case mood(imp: UUID, mood: String)
    /// Plays an animation, beat by beat.
    case animate(imp: UUID, beats: [AnimationBeat])
    /// A toss didn't work out (it bounces back): why.
    case refused(imp: UUID, reason: String)
    /// What it's saying to another Imp right now (nil: nothing).
    case speech(imp: UUID, speech: LinkSpeech?)
    /// A part of a file the phone asked for.
    case file(id: UUID, part: LinkFilePart)
    /// The file can't be sent: why.
    case fileFailed(id: UUID, reason: String)
    case pong
    /// Where else this Mac can be reached from the internet (a Hop, `host:port`), nil if nowhere.
    /// Sent after `welcome`, so a phone paired earlier learns it without pairing again.
    case route(hop: String?)
    /// The Mac took the pocket Imp in: it lives there now.
    case adopted(imp: UUID)
    /// The reply to a pocket Imp's `message`: what the Mac Imp said, or why it couldn't (`failed`).
    case answer(id: UUID, text: String, failed: Bool)
    /// A Mac Imp asks a pocket Imp something (`imp_message`). The phone answers with `answered`.
    case ask(id: UUID, from: LinkImp, to: UUID, text: String)
}

/// What you did to an Imp on the phone's screen.
public enum LinkFeeling: String, Codable, Sendable {
    case poke, cuddle, shake, drop
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
