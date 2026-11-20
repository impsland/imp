import Foundation
import ImpCore

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

    /// The sizes and wording the core remembers by.
    static let rules = ImpCore.memoryRules()
    /// Exchanges sent by default (an exchange: your turn, with every tool call and reply it led to).
    public static let defaultExchanges = Int(rules.defaultExchanges)
    /// Exchanges kept at most: as many as the longest "Remembers" choice.
    public static let storedExchanges = Int(rules.storedExchanges)
    /// "Remembers" with no limit: every exchange kept (up to `storedExchanges`) is sent. The default.
    public static let noLimit = Int.max
    /// The "Remembers" choices (exchanges sent with each message), besides no limit.
    public static let choices = rules.choices.map(Int.init)
    /// A tool result longer than this is clipped when it's remembered.
    public static let toolResultLimit = Int(rules.toolResultLimit)

    public init(messages: [ChatMessage] = [], recap: String? = nil) {
        self.messages = messages
        self.recap = recap
    }

    public var isEmpty: Bool { messages.isEmpty && recap == nil }

    var coreState: ImpCore.MemoryState { ImpCore.MemoryState(messages: messages.map(\.core), recap: recap) }

    private mutating func take(_ state: ImpCore.MemoryState) {
        messages = state.messages.map(ChatMessage.init); recap = state.recap
    }

    /// The model's input: the system prompt as it is, the recap (if any) as the opening exchange,
    /// the last `exchanges` exchanges (without tool calls and results unless `tools`), then the new turn.
    public func context(system: String, turn: ChatMessage, exchanges: Int = defaultExchanges, tools: Bool = true) -> [ChatMessage] {
        let kept = ImpCore.memoryContext(memory: coreState, exchanges: Self.count(exchanges), tools: tools)
        return [.system(system)] + kept.map(ChatMessage.init) + [turn]
    }

    /// Remembers one finished exchange: the user's turn and everything that followed it (the
    /// agent's new messages). The core drops pictures and clips long tool results.
    public mutating func remember(_ exchange: [ChatMessage]) {
        take(ImpCore.memoryRemember(memory: coreState, exchange: exchange.map(\.core)))
    }

    /// The chat recapped: `summary` was written from the first `covered` exchanges (all, by default).
    /// A blank summary changes nothing.
    public mutating func recapped(_ summary: String, covering covered: Int? = nil) {
        take(ImpCore.memoryRecapped(memory: coreState, summary: summary, covered: covered.map(Self.count)))
    }

    /// Exchanges remembered.
    public var exchangeCount: Int { Int(ImpCore.memoryExchangeCount(memory: coreState)) }

    /// A rough size of what's sent, in tokens.
    public func estimatedTokens(exchanges: Int = defaultExchanges, tools: Bool = true) -> Int {
        Int(ImpCore.memoryEstimatedTokens(memory: coreState, exchanges: Self.count(exchanges), tools: tools))
    }

    /// Splits messages into exchanges, each starting with a user message.
    static func exchanges(in messages: [ChatMessage]) -> [[ChatMessage]] {
        ImpCore.memoryExchanges(messages: messages.map(\.core)).map { $0.map(ChatMessage.init) }
    }

    /// A count the core takes (`noLimit` and the like stay within what it can hold).
    static func count(_ n: Int) -> UInt32 { UInt32(clamping: max(n, 0)) }
}

extension ChatMessage {
    var core: ImpCore.MemoryMessage {
        ImpCore.MemoryMessage(role: role, content: content,
                              toolCalls: (toolCalls ?? []).map { ImpCore.MemoryCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                              toolCallId: toolCallID, attachment: attachment == true)
    }

    init(_ m: ImpCore.MemoryMessage) {
        self.init(role: m.role, content: m.content,
                  toolCalls: m.toolCalls.isEmpty ? nil : m.toolCalls.map { ToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                  toolCallID: m.toolCallId, attachment: m.attachment ? true : nil)
    }
}

/// A chat with an Imp: what the chat view shows (`turns`) and what the model remembers of it
/// (`memory`). An Imp keeps any number of them. You carry on in one at a time.
public struct Chat: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var updated: Date
    public var turns: [ChatTurn]
    public var memory: ChatMemory
    /// The Imp this chat is with, when it's where two Imps talk (nil: a chat with you).
    public var peer: UUID?
    /// The long-chat notice (see `ChatHistory.checkContext`) was raised for this chat, and whether
    /// you waved it away. Optional, so chats saved before they existed still load.
    public var contextNoticed: Bool?
    public var contextDismissed: Bool?

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
        ImpCore.memoryChatTitle(request: turn.request, hasPicture: turn.picture != nil,
                                sender: turn.via == .imp ? turn.sender?.name : nil)
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

    public init(id: UUID, title: String, updated: Date, turns: Int, peer: UUID? = nil) {
        self.id = id; self.title = title; self.updated = updated; self.turns = turns; self.peer = peer
    }
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
/// the new one, which replaces it. There is only ever one.
public enum Recap {
    /// Introduces the recap in the opening message.
    public static let preface = ChatMemory.rules.recapPreface
    /// The model's side of the opening exchange.
    public static let acknowledgement = ChatMemory.rules.recapAcknowledgement
    /// The most transcript sent to be recapped (characters).
    public static let transcriptLimit = Int(ChatMemory.rules.transcriptLimit)

    /// The request that asks for a recap: the whole remembered chat (and any earlier recap) as a
    /// transcript, so it works with any model, tools or not.
    public static func request(_ memory: ChatMemory, name: String) -> [ChatMessage] {
        ImpCore.memoryRecapRequest(memory: memory.coreState, name: name).map(ChatMessage.init)
    }

    /// The remembered chat as plain text, at most `limit` characters.
    public static func transcript(_ memory: ChatMemory, toolLimit: Int = 1_500, limit: Int = transcriptLimit) -> String {
        ImpCore.memoryTranscript(memory: memory.coreState, toolLimit: ChatMemory.count(toolLimit), limit: ChatMemory.count(limit))
    }
}
