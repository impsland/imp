import Foundation

/// A conversation as JSON, for reading and copying next to the bubble view. The text is made from
/// the very turns (a chat with you) or lines (a talk between Imps) the bubble view shows, so the
/// two can never disagree about what was said.
public enum Transcript {
    /// The turns of a chat, as pretty JSON, oldest first as given.
    public static func json(_ turns: [ChatTurn]) -> String { text(turns) }

    /// The exchanges of a talk between two Imps, as pretty JSON.
    public static func json(_ lines: [TalkLine]) -> String { text(lines) }

    /// The turns in `json` (what `json(_:)` wrote); nil if it isn't that.
    public static func turns(fromJSON text: String) -> [ChatTurn]? { read(text) }

    /// The lines in `json` (what `json(_:)` wrote); nil if it isn't that.
    public static func lines(fromJSON text: String) -> [TalkLine]? { read(text) }

    private static func text<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static func read<T: Decodable>(_ text: String) -> T? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: Data(text.utf8))
    }
}

extension ChatHistory {
    /// The chats with you: the ones a conversation between two Imps (`peer`) is not part of. Those are
    /// listed as talks, so each conversation is listed once.
    public var chatsWithYou: [ChatSummary] { chats.filter { $0.peer == nil } }
}
