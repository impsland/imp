import Foundation

/// What an Imp remembers of one chat, as the model is sent it: every message after the system
/// prompt (your turns, its replies and, in between, the tools it called and what they returned),
/// plus a recap of whatever came before, once the chat has been recapped. The system prompt is
/// never touched: the recap goes in as the chat's opening exchange (see `Recap.opening`). Picture
/// bytes aren't kept here (they're saved in its workspace, by path).
public struct ChatMemory: Codable, Equatable, Sendable {
    /// Oldest first. Each exchange starts with a user message.
    public private(set) var messages: [ChatMessage] = []
    /// What the chat was about before `messages` (written by the model, see `Recap`).
    public private(set) var recap: String?

    /// Exchanges sent by default (an exchange: your turn, with every tool call and reply it led to).
    public static let defaultExchanges = 20
    /// Exchanges kept at most (older ones go: nothing sends them any more). As many as the longest
    /// "Remembers" choice, so whatever is picked there is really sent, and a recap sees all of it.
    public static let storedExchanges = 1_000
    /// The "Remembers" choices (exchanges sent with each message).
    public static let choices = [5, 10, 20, 50, 100, 200, 500, 1_000]
    /// A tool result longer than this is clipped when it's remembered (the model saw it whole
    /// when it called the tool; later turns rarely need every byte of a file it read).
    public static let toolResultLimit = 8_000

    public init(messages: [ChatMessage] = [], recap: String? = nil) {
        self.messages = messages
        self.recap = recap
    }

    public var isEmpty: Bool { messages.isEmpty && recap == nil }

    /// The model's input: the system prompt as it is, the recap (if any) as the opening exchange,
    /// the last `exchanges` exchanges (without tool calls and results unless `tools`), then the new turn.
    public func context(system: String, turn: ChatMessage, exchanges: Int = defaultExchanges, tools: Bool = true) -> [ChatMessage] {
        let recent = Self.exchanges(in: messages).suffix(max(exchanges, 0)).flatMap { $0 }
        return [.system(system)] + (recap.map(Recap.opening) ?? []) + (tools ? recent : Self.withoutTools(recent)) + [turn]
    }

    /// Remembers one finished exchange: the user's turn and everything that followed it (the
    /// agent's new messages). Pictures are dropped, long tool results clipped.
    public mutating func remember(_ exchange: [ChatMessage]) {
        let kept = exchange.filter { $0.attachment != true }.map { m -> ChatMessage in
            var m = Briefing.remembered(m)
            if m.role == "tool", let c = m.content, c.count > Self.toolResultLimit {
                m.content = String(c.prefix(Self.toolResultLimit)) + "\n…(clipped: \(c.count - Self.toolResultLimit) more characters)"
            }
            return m
        }
        messages += kept
        let all = Self.exchanges(in: messages)
        if all.count > Self.storedExchanges { messages = all.suffix(Self.storedExchanges).flatMap { $0 } }
    }

    /// The chat recapped: `summary` was written from the first `covered` exchanges (all, by default)
    /// and stands for them but the last, an earlier recap included (the request hands it over to be
    /// folded in). That last exchange stays, and so does anything said while the recap was written.
    /// An empty summary changes nothing: a recap that came back blank must not cost the chat what
    /// it remembered.
    public mutating func recapped(_ summary: String, covering covered: Int? = nil) {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recap = text
        let all = Self.exchanges(in: messages)
        messages = all.dropFirst(max(min(covered ?? all.count, all.count) - 1, 0)).flatMap { $0 }
    }

    /// Exchanges remembered.
    public var exchangeCount: Int { Self.exchanges(in: messages).count }

    /// A rough size of what's sent, in tokens (about four characters each).
    public func estimatedTokens(exchanges: Int = defaultExchanges, tools: Bool = true) -> Int {
        let sent = context(system: "", turn: .user(""), exchanges: exchanges, tools: tools)
        let chars = sent.reduce(0) { total, m in
            total + (m.content?.count ?? 0) + (m.toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count }
        }
        return chars / 4
    }

    /// Splits messages into exchanges, each starting with a user message (anything before the
    /// first one rides with it), so tool calls never lose their results.
    static func exchanges(in messages: [ChatMessage]) -> [[ChatMessage]] {
        var out: [[ChatMessage]] = []
        for m in messages {
            if (m.role == "user" && m.attachment != true) || out.isEmpty { out.append([m]) } else { out[out.count - 1].append(m) }
        }
        return out
    }

    /// Only what was said: your turns and its replies, no tool calls or results.
    static func withoutTools(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { m in
            m.role != "tool" && m.attachment != true && !(m.role == "assistant" && !(m.toolCalls ?? []).isEmpty)
        }
    }
}

/// A chat with an Imp: what the chat view shows (`turns`) and what the model remembers of it
/// (`memory`). An Imp keeps any number of them; you carry on in one at a time.
public struct Chat: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var updated: Date
    public var turns: [ChatTurn]
    public var memory: ChatMemory
    /// The Imp this chat is with, when it's where two Imps talk (nil: a chat with you).
    public var peer: UUID?

    public init(id: UUID = UUID(), title: String = "", created: Date = Date(), turns: [ChatTurn] = [], memory: ChatMemory = ChatMemory(),
                peer: UUID? = nil) {
        self.id = id; self.title = title; self.created = created; self.updated = turns.last?.date ?? created
        self.turns = turns; self.memory = memory; self.peer = peer
    }

    public var isEmpty: Bool { turns.isEmpty && memory.isEmpty }

    /// The list entry for this chat.
    public var summary: ChatSummary { ChatSummary(id: id, title: title, updated: updated, turns: turns.count, peer: peer) }

    /// A name from the first thing you asked: its first line, cut short.
    static func title(for turn: ChatTurn) -> String {
        var words = turn.request.isEmpty ? (turn.picture == nil ? "Chat" : "A picture") : turn.request
        if turn.via == .imp, let sender = turn.sender { words = "\(sender.name): \(words)" }
        let line = words.split(whereSeparator: \.isNewline).first.map(String.init) ?? words
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
    }
}

/// A saved chat, as listed (the chat itself loads when you open it).
public struct ChatSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var updated: Date
    public var turns: Int
    /// The Imp it's with, for a chat between two Imps.
    public var peer: UUID?
}

/// Recaps a chat that's grown long: the model sums it up, the summary replaces the messages
/// before the last exchange (`ChatMemory.recapped`), and the chat carries on with room to spare.
///
/// Where the recap goes: not in the system prompt (that stays the Imp's own, and stays cacheable),
/// but as the chat's opening exchange, right after it: a `user` message carrying the recap and a
/// short `assistant` acknowledgement. A user message, because it's context handed in from outside
/// (as a second `system` message it's dropped or merged by some providers, and an `assistant`
/// one would put words in the model's mouth and open the chat on its turn). The acknowledgement
/// keeps the roles alternating (user, assistant, user…), which strict chat templates require.
/// Recapping again works the same: the earlier recap goes into the request and is folded into
/// the new one, which replaces it; there is only ever one.
public enum Recap {
    /// Introduces the recap in the opening message.
    public static let preface = "Recap of our chat so far (it replaces the earlier messages, which aren't included):\n\n"
    /// The model's side of the opening exchange.
    public static let acknowledgement = "Understood. I'll carry on from this recap."
    /// The most transcript sent to be recapped (characters). Longer chats keep their newest part
    /// (and any earlier recap): a recap must fit the model, or it can never be made.
    public static let transcriptLimit = 240_000

    /// The opening exchange that stands for everything before the recap.
    public static func opening(_ recap: String) -> [ChatMessage] {
        [.user(preface + recap), .assistant(acknowledgement)]
    }

    /// The request that asks for a recap: the whole remembered chat (and any earlier recap) as a
    /// transcript, so it works with any model, tools or not.
    public static func request(_ memory: ChatMemory, name: String) -> [ChatMessage] {
        let system = """
        You write the recap of a chat between a user and \(name), an AI assistant, so the chat can \
        carry on without its full history. Keep what matters for continuing: the user's goals, \
        requests and preferences; decisions and facts established; files, paths, URLs and names of \
        anything made or used (exactly as written); what is still open; and what happened last. \
        If the chat starts with an earlier recap, fold everything in it that still matters into \
        yours: yours replaces it. Leave out small talk. Write in the language the user writes in, \
        as short bullet points, under 300 words. Reply with the recap only.
        """
        return [.system(system), .user("The chat to recap:\n\n" + transcript(memory))]
    }

    /// The remembered chat as plain text, at most `limit` characters: the earlier recap always,
    /// then as many of the newest messages as fit.
    public static func transcript(_ memory: ChatMemory, toolLimit: Int = 1_500, limit: Int = transcriptLimit) -> String {
        var lines: [String] = []
        for m in memory.messages {
            let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if m.attachment == true { continue }
            switch m.role {
            case "user": lines.append("User: \(text)")
            case "assistant":
                if !text.isEmpty { lines.append("Assistant: \(text)") }
                for call in m.toolCalls ?? [] { lines.append("Assistant called \(call.name)(\(clip(call.arguments, toolLimit)))") }
            case "tool": lines.append("Tool result: \(clip(text, toolLimit))")
            default: continue
            }
        }
        let head = memory.recap.map { "[Earlier recap]\n\($0)" }
        // Room for the earlier recap and the "left out" note, each with its separator.
        var budget = limit - (head.map { $0.count + 2 } ?? 0) - 64
        var kept: [String] = []
        for line in lines.reversed() {
            budget -= line.count + 2
            if budget < 0 { break }
            kept.append(line)
        }
        let left = lines.count - kept.count
        let note = left > 0 ? ["[\(left) earlier messages left out to fit]"] : []
        return ((head.map { [$0] } ?? []) + note + kept.reversed()).joined(separator: "\n\n")
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
