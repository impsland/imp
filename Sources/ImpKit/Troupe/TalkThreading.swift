import Foundation

/// Whether a message from one Imp to another goes on in their latest conversation or starts a new one.
///
/// Who decides is a setting (`ImpPreferences.talkThreading`):
/// - `recent`: a rule. Continue when the last message between the two is younger than the window
///   (`ImpPreferences.talkWindowMinutes`), else start a new conversation.
/// - `always` / `never`: continue the latest conversation, or always start a new one.
/// - `decides` (the default): the sending Imp says, with the `conversation` argument of `imp_message`
///   (`new` or `continue`). When it says nothing, or something else, the `recent` rule applies.
///
/// With no earlier conversation there is nothing to continue: it is always new. Only a talk in a
/// chat of its own (`ImpTalk.Place.own`) has conversations to choose from. Nothing travels on the
/// link for this: the Imp that receives the message decides, from its own chats.
public enum TalkThreading: String, Codable, CaseIterable, Sendable, Identifiable {
    case decides, recent, always, never

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .decides: String(localized: "The Imp decides")
        case .recent: String(localized: "Continue if recent")
        case .always: String(localized: "Always continue")
        case .never: String(localized: "Always start new")
        }
    }

    /// The most the window can be: a week.
    public static let maxWindowMinutes = 10_080

    /// Continue the latest conversation (true) or start a new one (false).
    /// `asked`: the sender's `conversation` argument. `last`: when the latest conversation between the two last had a message.
    public func continues(asked: String?, last: Date?, windowMinutes: Int, now: Date = Date()) -> Bool {
        guard let last else { return false }
        let recent = now.timeIntervalSince(last) < Double(max(windowMinutes, 0)) * 60
        switch self {
        case .always: return true
        case .never: return false
        case .recent: return recent
        case .decides:
            switch asked?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "new": return false
            case "continue": return true
            default: return recent
            }
        }
    }
}
