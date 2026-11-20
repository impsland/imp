import Foundation
import ImpCore

/// What a person wrote over how one tool reads to the model: its name and/or its description. What is nil stays as
/// the app made it. Kept per Imp by tool registry id (`ImpProfile.toolText`, the agent file's `toolText`).
///
/// A description may use `{imps}`, `{animations}` and `{place}` (`ToolText.placeholders`): the parts of a description
/// that change. Each tool has the ones it can fill (`ToolTextRow.placeholders`). Any other is left empty.
public struct ToolText: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) { self.name = name; self.description = description }

    /// Nothing written over.
    public var isEmpty: Bool { (name ?? "").isEmpty && (description ?? "").isEmpty }

    /// The placeholders a description may use (the core's list).
    public static var placeholders: [String] { ImpCore.toolPlaceholders() }

    /// Whether `name` is one the model can call a tool by (the core's rule: 1 to 64 letters, digits, `_` and `-`).
    public static func isValid(name: String) -> Bool { ImpCore.toolNameValid(name: name) }

    /// `text` with each `{key}` of `fills` filled and every other placeholder left empty.
    public static func expand(_ text: String, _ fills: [String: String]) -> String {
        let keys = fills.keys.sorted()
        return ImpCore.toolExpandPlaceholders(text: text, keys: keys, values: keys.map { fills[$0] ?? "" })
    }

    /// `description` with the parts that `fills` gave turned back into their placeholders (longest first): the text
    /// as a person edits it.
    public static func template(_ description: String, _ fills: [String: String]) -> String {
        var out = description
        for (key, value) in fills.sorted(by: { $0.value.count > $1.value.count }) where !value.isEmpty {
            out = out.replacingOccurrences(of: value, with: "{\(key)}")
        }
        return out
    }
}

/// One tool an Imp is offered, for the screen that edits how it reads.
public struct ToolTextRow: Hashable, Sendable, Identifiable {
    /// The registry id (`own.personality.imp_message`): what the override is kept under.
    public var id: String
    /// What the app calls it, and its description with the changing parts as `{placeholders}`.
    public var defaultName: String
    public var defaultDescription: String
    /// What the person wrote over it, if anything.
    public var text: ToolText?
    /// The placeholders this tool's description can use.
    public var placeholders: [String]

    public init(id: String, defaultName: String, defaultDescription: String, text: ToolText? = nil, placeholders: [String] = []) {
        self.id = id; self.defaultName = defaultName; self.defaultDescription = defaultDescription
        self.text = text; self.placeholders = placeholders
    }
}
