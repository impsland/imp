import Foundation

/// One chat as a file of its own, to keep, move to another Mac, or hand to another Imp and carry
/// on there. What the chat shows and what the Imp remembers of it (its recap included), in the same
/// shape a kit writes chats in:
///
///     { "impChat": 1, "app": "1.11.0", "imp": "Pip",
///       "chat": { "title", "created", "updated", "turns": […], "memory": { "recap", "messages": […] } } }
///
/// Read back as a new chat (fresh ids), cut to what a chat keeps. Pictures aren't in it (they stay
/// in the Imp's workspace), and a chat between two Imps can't be exported (it names a local Imp).
public enum ChatFile {
    public static let version = 1
    /// The biggest chat file read.
    public static let maxBytes = 20 * 1024 * 1024

    public enum Failure: LocalizedError, Equatable {
        case tooLarge, notAChat, empty
        public var errorDescription: String? {
            switch self {
            case .tooLarge: String(localized: "That file is too big to be a chat (the limit is \(ChatFile.maxBytes / 1_048_576) MB).")
            case .notAChat: String(localized: "That isn't a chat exported from Imp.")
            case .empty: String(localized: "That chat has nothing in it.")
            }
        }
    }

    /// Whether `chat` can be written as a file: something was said, and it isn't between two Imps.
    public static func canExport(_ chat: Chat) -> Bool { chat.peer == nil && !chat.isEmpty }

    /// The chat as JSON text.
    public static func text(_ chat: Chat, imp: String? = nil, app: String? = nil) -> String {
        var top: [String: JSONValue] = ["impChat": .number(Double(version)), "chat": chat.kitJSON]
        if let imp, !imp.isEmpty { top["imp"] = .string(imp) }
        if let app, !app.isEmpty { top["app"] = .string(app) }
        return JSONValue.object(top).kitText(pretty: true)
    }

    /// A chat from a file's text: a new one, ready to adopt. Also takes a bare chat object (as
    /// written inside a kit).
    public static func read(_ text: String) throws -> Chat {
        guard text.utf8.count <= maxBytes else { throw Failure.tooLarge }
        guard let json = try? JSONValue(jsonString: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              case .object = json else { throw Failure.notAChat }
        let body: JSONValue
        if json["impChat"] != nil, let chat = json["chat"] { body = chat }
        else if json["turns"] != nil || json["memory"] != nil { body = json }
        else { throw Failure.notAChat }
        guard let chat = Chat(kit: body) else { throw Failure.empty }
        return chat
    }

    /// A file name for the chat: its title, without characters Finder won't take.
    public static func fileName(_ chat: Chat) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let base = chat.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Chat" : String(base.prefix(60))) + ".json"
    }
}
