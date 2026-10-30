import Foundation

/// One exchange with an Imp, as shown in its chat: what you asked, the tools it used (each
/// with its request and response) and its reply, or the error that stopped it.
public struct ChatTurn: Codable, Equatable, Identifiable, Sendable {
    public struct Step: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var icon: String
        public var title: String
        public var request: String
        public var response: String?
        public var failed: Bool

        public init(id: UUID = UUID(), icon: String, title: String, request: String, response: String?, failed: Bool) {
            self.id = id; self.icon = icon; self.title = title; self.request = request; self.response = response; self.failed = failed
        }
    }

    /// How you asked.
    public enum Via: String, Codable, Sendable {
        case typed, spoken, shortcut
        /// Not a request: the chat was recapped (`reply` is the recap).
        case recap
        /// Another Imp asked (`imp_message`): `sender` says which, `request` is its question.
        case imp
    }

    /// The Imp that sent a message: kept with the turn, so the chat shows who said it and in
    /// whose colour, even after that Imp is renamed or gone.
    public struct Sender: Codable, Equatable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var hue: Double
        public init(id: UUID, name: String, hue: Double) { self.id = id; self.name = name; self.hue = hue }
    }

    public var id: UUID
    public var date: Date
    /// Your words (typed or said), or the shortcut's name.
    public var request: String
    /// The answer, or what went wrong (`failed`).
    public var reply: String
    public var failed: Bool
    public var steps: [Step]
    // What came with the request. Optional, so turns saved before these existed still load.
    public var via: Via?
    /// A shortcut's instruction (what to do with what was copied).
    public var instruction: String?
    /// The text a shortcut was run on.
    public var copiedText: String?
    /// The picture handed over (pasted into the text box, or copied for a shortcut): its file.
    public var picture: String?
    /// Who asked, when it was another Imp (`via` is `.imp`).
    public var sender: Sender?

    public init(id: UUID = UUID(), date: Date = Date(), request: String, reply: String = "", failed: Bool = false,
                steps: [Step] = [], via: Via? = nil, instruction: String? = nil, copiedText: String? = nil, picture: String? = nil,
                sender: Sender? = nil) {
        self.id = id; self.date = date; self.request = request; self.reply = reply; self.failed = failed; self.steps = steps
        self.via = via; self.instruction = instruction; self.copiedText = copiedText; self.picture = picture; self.sender = sender
    }
}

/// An Imp's chats, kept across launches: the one you're in (loaded) and the list of the rest.
/// Each chat is a file of its own, beside an index (`index.json`) of titles and the current one,
/// in `~/Library/Application Support/Imp/Chats/<imp id>/`. Not in the Imp's workspace: its
/// commands run there and have no business editing what it said.
public struct ChatHistory: Sendable {
    /// Turns a chat keeps: older ones are dropped, so the file stays a sensible size. The chat
    /// view shows them a page at a time, newest first.
    public static let limit = 2_000

    /// The chat you're in. Empty until something is said (and only saved from then on).
    public private(set) var current = Chat()
    /// Every saved chat, newest first (the current one included, once it's saved).
    public private(set) var chats: [ChatSummary] = []
    /// Where they're kept; nil keeps them in memory only.
    public let folder: URL?

    public static func folder(for imp: UUID) -> URL {
        support.appendingPathComponent("Imp/Chats/\(imp.uuidString)", isDirectory: true)
    }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Loads the saved chats and reopens the one you were in (unreadable files start afresh).
    public init(folder: URL?) {
        self.folder = folder
        guard let folder else { return }
        Self.flush()                                   // an earlier instance may still be writing
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let index = try? Self.decoder.decode(Index.self, from: data) {
            chats = index.chats
            if let id = index.current, let chat = load(id) { current = chat }
        }
    }

    public var turns: [ChatTurn] { current.turns }
    public var isEmpty: Bool { current.isEmpty }

    /// The newest `count` turns of the current chat, oldest first.
    public func latest(_ count: Int) -> ArraySlice<ChatTurn> { current.turns.suffix(max(count, 0)) }

    /// A saved chat, read whole (the one you're in as it is now). Nil if it's gone.
    public func chat(_ id: UUID) -> Chat? { id == current.id ? current : load(id) }

    /// Adds a turn to the current chat, with what the model should remember of it (the user's
    /// turn and the agent's new messages; nil for a failure, which the model never saw answered).
    public mutating func append(_ turn: ChatTurn, remembering exchange: [ChatMessage]? = nil) {
        Self.add(turn, remembering: exchange, to: &current)
        save(current)
    }

    private static func add(_ turn: ChatTurn, remembering exchange: [ChatMessage]?, to chat: inout Chat) {
        if chat.title.isEmpty, turn.via != .recap { chat.title = Chat.title(for: turn) }
        chat.turns.append(turn)
        if chat.turns.count > limit { chat.turns.removeFirst(chat.turns.count - limit) }
        if let exchange, !exchange.isEmpty { chat.memory.remember(exchange) }
        chat.updated = turn.date
    }

    /// The saved chat with another Imp (one per peer, found by the peer's id, never by title).
    public func chat(with peer: UUID) -> ChatSummary? { chats.first { $0.peer == peer } }

    /// What the model remembers of its chat with `peer` (nothing before the first message).
    /// Reads the file if it isn't the chat you're in.
    public func memory(withPeer peer: UUID) -> ChatMemory {
        if current.peer == peer { return current.memory }
        return chat(with: peer).flatMap { load($0.id) }?.memory ?? ChatMemory()
    }

    /// Adds a turn to the chat with `peer`, made on the first one ("With Pip"), without changing
    /// the chat you're in. It is listed first like any chat that was just talked in.
    public mutating func append(_ turn: ChatTurn, remembering exchange: [ChatMessage]? = nil, withPeer peer: ChatTurn.Sender) {
        if current.peer == peer.id { return append(turn, remembering: exchange) }
        let saved = chat(with: peer.id)
        var chat = saved.flatMap { load($0.id) }
            ?? Chat(id: saved?.id ?? UUID(), title: saved?.title ?? String(localized: "With \(peer.name)"), peer: peer.id)
        Self.add(turn, remembering: exchange, to: &chat)
        save(chat)
    }

    /// Puts a whole chat that came from elsewhere (a kit) in the list, first, without changing the chat
    /// you're in. Add them oldest first and the newest ends up on top.
    public mutating func adopt(_ chat: Chat) { save(chat, first: true) }

    /// Every saved chat, read from its file (the one you're in as it is now), newest first.
    public func savedChats() -> [Chat] {
        chats.compactMap { $0.id == current.id ? current : load($0.id) }
    }

    /// The model's recap replaces what it remembered before the last exchange, and shows in the
    /// chat as a turn of its own.
    public mutating func recap(_ summary: String, covering covered: Int? = nil, at date: Date = Date()) {
        current.memory.recapped(summary, covering: covered)
        append(ChatTurn(date: date, request: "Recap", reply: summary, via: .recap))
    }

    /// Starts a fresh chat (the current one stays in the list). Nothing happens in an empty one.
    public mutating func startNew() {
        guard !current.isEmpty else { return }
        current = Chat()
        saveIndex()
    }

    /// Carries on in a saved chat.
    public mutating func open(_ id: UUID) {
        guard id != current.id, let chat = load(id) else { return }
        current = chat
        saveIndex()
    }

    public mutating func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].title = t
        if id == current.id {
            current.title = t
            save(current, first: false)
        } else if var chat = load(id) {
            chat.title = t
            save(chat, first: false)
        } else {
            saveIndex()
        }
    }

    /// Deletes a chat for good (file included). Deleting the current one starts a fresh chat.
    public mutating func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if id == current.id { current = Chat() }
        saveIndex()
        guard let file = file(id) else { return }
        Self.writer.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Deletes an Imp's chats for good, after any save still queued for them.
    public static func deleteFolder(for imp: UUID) {
        let folder = folder(for: imp)
        writer.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Deletes every chat (the folder too).
    public mutating func deleteAll() {
        chats = []
        current = Chat()
        guard let folder else { return }
        Self.writer.async { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Files

    private struct Index: Codable {
        var current: UUID?
        var chats: [ChatSummary]
    }

    private func file(_ id: UUID) -> URL? { folder?.appendingPathComponent("\(id.uuidString).json") }

    /// Reads a saved chat (after any pending write to it).
    private func load(_ id: UUID) -> Chat? {
        Self.flush()
        guard let file = file(id), let data = try? Data(contentsOf: file) else { return nil }
        return try? Self.decoder.decode(Chat.self, from: data)
    }

    /// Saves a chat and lists it first, or where it was (an empty one is never saved).
    private mutating func save(_ chat: Chat, first: Bool = true) {
        guard !chat.isEmpty else { return saveIndex() }
        if !first, let i = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[i] = chat.summary
        } else {
            chats.removeAll { $0.id == chat.id }
            chats.insert(chat.summary, at: 0)
        }
        guard let file = file(chat.id), let data = try? Self.encoder.encode(chat) else { return saveIndex() }
        write(data, to: file)
        saveIndex()
    }

    private func saveIndex() {
        guard let folder, let data = try? Self.encoder.encode(Index(current: current.isEmpty ? nil : current.id, chats: chats))
        else { return }
        write(data, to: folder.appendingPathComponent("index.json"))
    }

    /// Written off the main thread (a chat can be a few megabytes); later saves win, since each
    /// writes the whole file atomically.
    private func write(_ data: Data, to file: URL) {
        Self.writer.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// One queue for every write, so they land in order.
    private static let writer = DispatchQueue(label: "app.imp.history", qos: .utility)
    /// Waits for pending writes (tests).
    static func flush() { writer.sync {} }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
