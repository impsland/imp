import ImpCore
import Foundation

// Imp Link messages (see `docs/connecting/link.md`). They are the JSON the core reads and writes, one per frame.
// The core checks every message that comes in, so these are shapes and nothing more.

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
        self.height = height
        self.speed = speed
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
    /// What the Imp says it is good at (one or two lines), for the Imps that may message it. Untrusted
    /// when it comes from another device: sanitize with `troupeAboutLine` before showing or using it.
    public var about: String?
    /// What it can do (`shell`, `browser`, its tool servers' names), likewise untrusted.
    public var abilities: [String]

    public init(id: UUID, name: String, hue: Double, scale: Double, traits: ImpTraits, about: String? = nil, abilities: [String] = []) {
        self.id = id; self.name = name; self.hue = hue; self.scale = scale; self.traits = traits
        self.about = about; self.abilities = abilities
    }

    /// `abilities`: what this device computed for the Imp (`ImpAbilities`). The profile alone can't know its tool servers' names.
    public init(_ profile: ImpProfile, abilities: [String] = []) {
        self.init(id: profile.id, name: profile.name, hue: profile.hue, scale: profile.scale, traits: profile.traits,
                  about: profile.about.flatMap { ImpCore.troupeAboutLine(text: $0) },
                  abilities: ImpCore.troupeAbilityTags(tags: abilities))
    }

    private enum CodingKeys: String, CodingKey { case id, name, hue, scale, traits, about, abilities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  hue: try c.decode(Double.self, forKey: .hue), scale: try c.decode(Double.self, forKey: .scale),
                  traits: try c.decode(ImpTraits.self, forKey: .traits),
                  about: try c.decodeIfPresent(String.self, forKey: .about),
                  abilities: try c.decodeIfPresent([String].self, forKey: .abilities) ?? [])
    }

    /// Written only when there is something to say: an empty description or list stays off the wire.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(hue, forKey: .hue)
        try c.encode(scale, forKey: .scale); try c.encode(traits, forKey: .traits)
        if let about, !about.isEmpty { try c.encode(about, forKey: .about) }
        if !abilities.isEmpty { try c.encode(abilities, forKey: .abilities) }
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
    /// Which of `steps` are the Imp thinking ("Thought for 3s"), by position. Only the title travels, never what it thought.
    public var thoughts: [Int]?
    /// What it thought at those positions, on the device that thought it (a pocket Imp). Never sent: not part of the wire shape.
    public var reasoning: [Int: String] = [:]
    /// True when `request` is not a request but the answer of the Imp `from` to a message this Imp sent without waiting.
    public var answer: Bool?

    public init(id: UUID, date: Date, request: String, from: String? = nil, reply: String, failed: Bool, steps: [String] = [],
                thoughts: [Int]? = nil, answer: Bool? = nil) {
        self.id = id; self.date = date; self.request = request; self.from = from; self.answer = answer
        self.reply = reply; self.failed = failed; self.steps = steps; self.thoughts = thoughts
    }

    public init(_ turn: ChatTurn) {
        let thoughts = turn.steps.indices.filter { turn.steps[$0].isThought }
        self.init(id: turn.id, date: turn.date, request: turn.request, from: turn.sender?.name, reply: turn.reply,
                  failed: turn.failed, steps: turn.steps.map(\.title), thoughts: thoughts.isEmpty ? nil : thoughts,
                  answer: turn.via == .answer ? true : nil)
    }

    /// A turn for showing on the device that has it: what the Imp thought is kept with it.
    public init(local turn: ChatTurn) {
        self.init(turn)
        for i in turn.steps.indices where turn.steps[i].isThought { reasoning[i] = turn.steps[i].response ?? "" }
    }

    private enum CodingKeys: String, CodingKey { case id, date, request, from, reply, failed, steps, thoughts, answer }
}

/// One saved chat of an Imp, as its holder lists it.
public struct LinkChat: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var updated: Date

    public init(id: UUID, title: String, updated: Date) { self.id = id; self.title = title; self.updated = updated }

    public init(_ summary: ChatSummary) { self.init(id: summary.id, title: String(summary.title.prefix(LinkChats.longestTitle)), updated: summary.updated) }
}

public enum LinkChats {
    /// Chats a home lists for its holder (newest first), and the longest title it sends.
    public static let limit = 30
    public static let longestTitle = 200

    /// What a home tells of its chats with you: the saved ones, newest first (a chat with another Imp is a talk, not listed).
    public static func list(_ chats: [ChatSummary]) -> [LinkChat] {
        chats.filter { $0.peer == nil }.sorted { $0.updated > $1.updated }.prefix(limit).map(LinkChat.init)
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
    /// What it thinks right now, on the device that thinks it (a pocket Imp). Never sent: a visitor is only told
    /// "Thinking…" (`status`).
    public var reasoning = ""

    private enum CodingKeys: String, CodingKey { case request, status, partial, from }

    public init(request: String, status: String?, partial: String, from: String? = nil, reasoning: String = "") {
        self.request = request; self.status = status; self.partial = partial; self.from = from; self.reasoning = reasoning
    }
}

/// An Imp talking with another Imp (`imp_message`), as its speech bubble shows it: asked by one,
/// answering it, or waiting for another's answer.
public struct LinkSpeech: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable {
        /// Another Imp asked this one something. It's thinking.
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
/// either side can send any message. What a device does with one depends on who sent it
/// and what that sender may do.
/// Messages this version does not know decode to nil and are ignored. `imp` is always the Imp's id.
public enum LinkMessage: Codable, Sendable, Equatable {
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
    /// Carry on in one of the chats the home listed (`chats`).
    case openChat(imp: UUID, chat: UUID)
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
    /// Its saved chats, newest first (at most `LinkChats.limit`), and the id of the one it is in, which isn't saved yet
    /// while it is empty. Sent with `chat` whenever either changes.
    case chats(imp: UUID, current: UUID, chats: [LinkChat])
    /// What it's working on (nil: nothing).
    case work(imp: UUID, work: LinkWork?)
    /// Its mood changed (a `Mood` raw value).
    case mood(imp: UUID, mood: String)
    /// Whether it has a brain it can think with at home (a service, a model and, where one is
    /// needed, a key). Sent with everything else to a new holder and whenever it changes. Without
    /// one it sleeps wherever its body is (`Wakefulness`), and asking it is refused there at once.
    /// `tools`: whether the home lets it use its tools for what this holder asks (the holder is one of
    /// the owner's devices there).
    case brain(imp: UUID, ready: Bool, tools: Bool)
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
    /// answers. A device that isn't it forwards the question there once (`forwarded`).
    case message(id: UUID, from: LinkImp, to: UUID, toHome: UUID, text: String, forwarded: Bool)
    /// The reply to a `message`: what the Imp said, or why it couldn't (`failed`).
    case answer(id: UUID, text: String, failed: Bool)

    // MARK: Moving in for good

    /// An Imp hatched here moves to the receiver for good: `kit` is its kit (`PocketImp.adoption`).
    /// The receiver answers `adopted` once its user agreed, or `declined`. The sender deletes its
    /// copy only after `adopted`.
    case adopt(transfer: UUID, imp: UUID, kit: String, secrets: LinkSecrets, entry: LinkEntry)
    case adopted(transfer: UUID)
}

