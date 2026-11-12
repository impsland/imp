import Foundation

// Talks between Imps. Each Imp files the questions it was asked by another Imp in its own chats
// (`ChatTurn.sender`), so one conversation between two Imps lives in two places: what A asked B is in
// B's chats, what B asked A is in A's. `TalkLog` puts both halves back together, for reading.

/// One exchange between two Imps: one asked, the other answered (or couldn't).
public struct TalkLine: Codable, Sendable, Equatable, Identifiable {
    /// The turn's id in the chat of the Imp that answered.
    public var id: UUID
    public var date: Date
    /// Who asked.
    public var asker: ChatTurn.Sender
    /// Who answered.
    public var answerer: ChatTurn.Sender
    public var question: String
    public var reply: String
    public var failed: Bool

    public init(id: UUID, date: Date, asker: ChatTurn.Sender, answerer: ChatTurn.Sender, question: String, reply: String, failed: Bool) {
        self.id = id; self.date = date; self.asker = asker; self.answerer = answerer
        self.question = question; self.reply = reply; self.failed = failed
    }
}

/// Everything one Imp and another said to each other, both ways, oldest first.
public struct TalkThread: Codable, Sendable, Equatable, Identifiable {
    /// The other Imp (as it was last seen: its name and colour).
    public var peer: ChatTurn.Sender
    public var lines: [TalkLine]

    public var id: UUID { peer.id }
    public var updated: Date { lines.last?.date ?? .distantPast }

    public init(peer: ChatTurn.Sender, lines: [TalkLine]) {
        self.peer = peer; self.lines = lines
    }
}

public enum TalkLog {
    /// Lines a thread keeps (the newest), and threads a list keeps: enough to read back, small
    /// enough to send to a phone in one go.
    public static let maxLines = 100
    public static let maxThreads = 30

    /// The exchanges in one Imp's chats: every turn another Imp asked it. `me` is that Imp.
    public static func lines(answeredBy me: ChatTurn.Sender, in chats: [Chat]) -> [TalkLine] {
        chats.flatMap(\.turns).compactMap { turn in
            guard let asker = turn.sender, asker.id != me.id else { return nil }
            return TalkLine(id: turn.id, date: turn.date, asker: asker, answerer: me, question: turn.request,
                            reply: turn.reply, failed: turn.failed)
        }
    }

    /// The talks `me` had, one thread per other Imp, newest first. `lines` may come from anywhere
    /// (every Imp's chats, the Mac's and the phone's) and overlap: each exchange counts once, and
    /// only the ones `me` took part in count. A peer's name and colour are the latest it had.
    public static func threads(of me: UUID, from lines: [TalkLine]) -> [TalkThread] {
        var seen = Set<UUID>()
        var byPeer: [UUID: [TalkLine]] = [:]
        for line in lines.sorted(by: { $0.date < $1.date }) where seen.insert(line.id).inserted {
            if line.asker.id == me, line.answerer.id != me { byPeer[line.answerer.id, default: []].append(line) }
            else if line.answerer.id == me, line.asker.id != me { byPeer[line.asker.id, default: []].append(line) }
        }
        return byPeer.compactMap { id, lines -> TalkThread? in
            guard let last = lines.last else { return nil }
            let peer = last.asker.id == id ? last.asker : last.answerer
            return TalkThread(peer: peer, lines: Array(lines.suffix(maxLines)))
        }
        .sorted { $0.updated > $1.updated }
        .prefix(maxThreads).map { $0 }
    }

    /// Lines for one `LinkUpdate.talks`: the newest few hundred, each text cut to a readable length,
    /// so they always fit a frame.
    public static func forLink(_ lines: [TalkLine], limit: Int = 300, textLimit: Int = 1_500) -> [TalkLine] {
        lines.sorted { $0.date < $1.date }.suffix(limit).map { line in
            var line = line
            line.question = String(line.question.prefix(textLimit))
            line.reply = String(line.reply.prefix(textLimit))
            return line
        }
    }
}
