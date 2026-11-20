import Testing
@testable import ImpKit

@Suite struct ToolTextEditorTests {
    private let rows = [
        ToolTextRow(id: "own.personality.imp_message", defaultName: "imp_message", defaultDescription: "Message: {imps}", text: nil, placeholders: ["imps"]),
        ToolTextRow(id: "mcp.files.read_file", defaultName: "files_read_file", defaultDescription: "Reads.", text: nil, placeholders: []),
    ]

    @Test func nameRules() {
        let id = rows[0].id
        #expect(ToolTextEditor.nameProblem("", for: id, among: rows, texts: [:]) == nil)
        #expect(ToolTextEditor.nameProblem("imp_message", for: id, among: rows, texts: [:]) == nil)
        #expect(ToolTextEditor.nameProblem("tell friends", for: id, among: rows, texts: [:]) == .invalid)
        #expect(ToolTextEditor.nameProblem("files_read_file", for: id, among: rows, texts: [:]) == .taken)
        // Another tool renamed away frees its old name, and holds its new one.
        let texts = [rows[1].id: ToolText(name: "read")]
        #expect(ToolTextEditor.nameProblem("files_read_file", for: id, among: rows, texts: texts) == nil)
        #expect(ToolTextEditor.nameProblem("read", for: id, among: rows, texts: texts) == .taken)
    }

    @Test func droppedPlaceholders() {
        #expect(ToolTextEditor.droppedPlaceholders(rows[0], edited: "Tell someone.") == ["imps"])
        #expect(ToolTextEditor.droppedPlaceholders(rows[0], edited: "To {imps}.").isEmpty)
        #expect(ToolTextEditor.droppedPlaceholders(rows[1], edited: "x").isEmpty)
    }

    @Test func resultKeepsOnlyWhatChanged() {
        #expect(ToolTextEditor.result(name: "", description: "Message: {imps}", for: rows[0]) == nil)
        #expect(ToolTextEditor.result(name: "tell", description: "Message: {imps}", for: rows[0]) == ToolText(name: "tell", description: nil))
        #expect(ToolTextEditor.result(name: "imp_message", description: "Hi", for: rows[0]) == ToolText(name: nil, description: "Hi"))
        // Reset to default fills both fields with the defaults: confirming that keeps no edit at all.
        #expect(ToolTextEditor.result(name: rows[0].defaultName, description: rows[0].defaultDescription, for: rows[0]) == nil)
    }
}
