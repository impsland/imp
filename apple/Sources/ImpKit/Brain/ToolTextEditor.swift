import Foundation

/// The rules of the sheet that edits how one tool reads to the model, apart from the screen so they can be tested:
/// what is wrong with a name, which placeholders an edit lost, and what to keep when the sheet is confirmed.
public enum ToolTextEditor {
    public enum NameProblem: Hashable, Sendable {
        /// Not 1 to 64 letters, digits, `_` and `-`.
        case invalid
        /// Another tool of the Imp is already called that.
        case taken
    }

    /// The name the model sees for a tool: what was written over it when that is allowed, else its own.
    public static func effectiveName(_ row: ToolTextRow, texts: [String: ToolText]) -> String {
        if let name = texts[row.id]?.name, !name.isEmpty, ToolText.isValid(name: name) { return name }
        return row.defaultName
    }

    /// What is wrong with `name` for the tool `id`, or nil. An empty name is fine (the tool keeps its own), and so is
    /// its own name. `texts` is what is written over the other tools now.
    public static func nameProblem(_ name: String, for id: String, among rows: [ToolTextRow], texts: [String: ToolText]) -> NameProblem? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        if !ToolText.isValid(name: name) { return .invalid }
        let taken = rows.filter { $0.id != id }.map { effectiveName($0, texts: texts) }
        return taken.contains(name) ? .taken : nil
    }

    /// The placeholders the default description uses that `edited` no longer has.
    public static func droppedPlaceholders(_ row: ToolTextRow, edited: String) -> [String] {
        row.placeholders.filter { row.defaultDescription.contains("{\($0)}") && !edited.contains("{\($0)}") }
    }

    /// What to keep for the tool once the sheet is confirmed: nil (no override) when both fields are empty or as the
    /// app wrote them.
    public static func result(name: String, description: String, for row: ToolTextRow) -> ToolText? {
        let name = name.trimmingCharacters(in: .whitespaces)
        let text = ToolText(name: name.isEmpty || name == row.defaultName ? nil : name,
                            description: description.isEmpty || description == row.defaultDescription ? nil : description)
        return text.isEmpty ? nil : text
    }
}
