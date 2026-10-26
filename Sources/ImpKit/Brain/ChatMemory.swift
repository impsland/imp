import Foundation

/// What an Imp remembers of one chat, as the model is sent it: every message after the system
/// prompt (your turns, its replies and, in between, the tools it called and what they returned),
/// plus a recap of whatever came before, once the chat has been recapped. Picture bytes aren't
/// kept here (they're saved in its workspace, by path).
public struct ChatMemory: Codable, Equatable, Sendable {
    /// Oldest first. Each exchange starts with a user message.
    public private(set) var messages: [ChatMessage] = []
    /// What the chat was about before `messages` (written by the model, see `Recap`).
    public private(set) var recap: String?

    /// Exchanges sent by default (an exchange: your turn, with every tool call and reply it led to).
    public static let defaultExchanges = 20
    /// Exchanges kept at most (older ones go: nothing sends them any more).
    public static let storedExchanges = 200
    /// A tool result longer than this is clipped when it's remembered (the model saw it whole
    /// when it called the tool; later turns rarely need every byte of a file it read).
    public static let toolResultLimit = 8_000

    public init(messages: [ChatMessage] = [], recap: String? = nil) {
        self.messages = messages
        self.recap = recap
    }

    public var isEmpty: Bool { messages.isEmpty && recap == nil }

    /// The model's input: the system prompt (with the recap, if any), the last `exchanges`
    /// exchanges (without tool calls and results unless `tools`), then the new turn.
    public func context(system: String, turn: ChatMessage, exchanges: Int = defaultExchanges, tools: Bool = true) -> [ChatMessage] {
        var prompt = system
        if let recap { prompt += (prompt.isEmpty ? "" : "\n\n") + Recap.preface + recap }
        let recent = Self.exchanges(in: messages).suffix(max(exchanges, 0)).flatMap { $0 }
        return [.system(prompt)] + (tools ? recent : Self.withoutTools(recent)) + [turn]
    }

    /// Remembers one finished exchange: the user's turn and everything that followed it (the
    /// agent's new messages). Pictures are dropped, long tool results clipped.
    public mutating func remember(_ exchange: [ChatMessage]) {
        let kept = exchange.map { m -> ChatMessage in
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

    /// The chat recapped: `summary` stands for everything but the last exchange.
    public mutating func recapped(_ summary: String) {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        recap = text.isEmpty ? nil : text
        messages = Self.exchanges(in: messages).last ?? []
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
            if m.role == "user" || out.isEmpty { out.append([m]) } else { out[out.count - 1].append(m) }
        }
        return out
    }

    /// Only what was said: your turns and its replies, no tool calls or results.
    static func withoutTools(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter { m in
            m.role != "tool" && !(m.role == "assistant" && !(m.toolCalls ?? []).isEmpty)
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

    public init(id: UUID = UUID(), title: String = "", created: Date = Date(), turns: [ChatTurn] = [], memory: ChatMemory = ChatMemory()) {
        self.id = id; self.title = title; self.created = created; self.updated = turns.last?.date ?? created
        self.turns = turns; self.memory = memory
    }

    public var isEmpty: Bool { turns.isEmpty && memory.isEmpty }

    /// The list entry for this chat.
    public var summary: ChatSummary { ChatSummary(id: id, title: title, updated: updated, turns: turns.count) }

    /// A name from the first thing you asked: its first line, cut short.
    static func title(for turn: ChatTurn) -> String {
        let words = turn.request.isEmpty ? (turn.picture == nil ? "Chat" : "A picture") : turn.request
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
}

/// Recaps a chat that's grown long: the model sums it up, the summary replaces the messages
/// before the last exchange (`ChatMemory.recapped`), and the chat carries on with room to spare.
public enum Recap {
    /// Introduces the recap in the system prompt.
    public static let preface = "Recap of this chat so far (the earlier messages were replaced by it):\n"

    /// The request that asks for a recap: the whole remembered chat (and any earlier recap) as a
    /// transcript, so it works with any model, tools or not.
    public static func request(_ memory: ChatMemory, name: String) -> [ChatMessage] {
        let system = """
        You write the recap of a chat between a user and \(name), an AI assistant, so the chat can \
        carry on without its full history. Keep what matters for continuing: the user's goals, \
        requests and preferences; decisions and facts established; files, paths, URLs and names of \
        anything made or used (exactly as written); what is still open; and what happened last. \
        Leave out small talk. Write in the language the user writes in, as short bullet points, \
        under 250 words. Reply with the recap only.
        """
        return [.system(system), .user("The chat to recap:\n\n" + transcript(memory))]
    }

    /// The remembered chat as plain text.
    public static func transcript(_ memory: ChatMemory, toolLimit: Int = 1_500) -> String {
        var lines: [String] = []
        if let recap = memory.recap { lines.append("[Earlier recap]\n\(recap)") }
        for m in memory.messages {
            let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch m.role {
            case "user": lines.append("User: \(text)")
            case "assistant":
                if !text.isEmpty { lines.append("Assistant: \(text)") }
                for call in m.toolCalls ?? [] { lines.append("Assistant called \(call.name)(\(clip(call.arguments, toolLimit)))") }
            case "tool": lines.append("Tool result: \(clip(text, toolLimit))")
            default: continue
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }
}
