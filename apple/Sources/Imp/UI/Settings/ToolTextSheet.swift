import ImpDesign
import ImpKit
import SwiftUI

extension AppModel {
    /// Every tool the Imp has, switched on or off, with how it reads to the model now: its own tools (even the ones that are
    /// only offered while other Imps are out) and the tools of its MCP servers. No key is read.
    func toolTextRows(for imp: ImpProfile) async -> [ToolTextRow] {
        var members: [ToolProvider] = [ImpTools(host: OwnToolHost(app: self, imp: imp.id, messaging: true), editing: true)]
        if !imp.servers.isEmpty { members.append(MCPScope(hub: assistant.hub, servers: Set(imp.servers), workspace: Workspace.directory(for: imp.id))) }
        return await ToolSet(members, selection: imp.toolSelection).allTextRows()
    }
}

/// The small mark and the button of a tool's row: the mark says its wording was changed, the pencil opens the sheet that
/// changes it. Hovering the pencil shows what the model reads now.
struct ToolTextButton: View {
    @Binding var imp: ImpProfile
    let model: AppModel
    let tool: ToolEntry
    let symbol: String
    var server: String?
    @State private var open = false
    @Environment(\.impTint) private var tint

    var body: some View {
        let text = imp.toolText[tool.id]
        HStack(spacing: Spacing.hairline) {
            if text != nil {
                Image(systemName: "pencil.circle.fill").font(.icon(.small)).foregroundStyle(LegibleTint(tint))
                    .help(Text("tooltext.edited")).accessibilityLabel(Text("tooltext.edited"))
            }
            HoverIconButton(systemName: "pencil", help: text?.description.map { LocalizedStringKey($0) } ?? "tooltext.edit") { open = true }
                .accessibilityIdentifier("tool.text")
        }
        .sheet(isPresented: $open) {
            ToolTextSheet(imp: $imp, model: model, tool: tool, symbol: symbol, server: server)
                .environment(\.impTint, tint).tint(tint)
        }
    }
}

/// Edits how one tool reads to the model: the name it is called by and the description it is given. Confirming keeps
/// only what differs from the app's wording. Cancel leaves the Imp as it was. The default is the app's, or the MCP server's.
struct ToolTextSheet: View {
    @Binding var imp: ImpProfile
    let model: AppModel?
    let tool: ToolEntry
    let symbol: String
    /// The MCP server the tool comes from, if it is one's.
    var server: String?
    /// The tools of the Imp: given by a design render, else read when the sheet opens.
    var preset: [ToolTextRow]?
    @State private var rows: [ToolTextRow]?
    @State private var name = ""
    @State private var description = ""
    @State private var filled = false
    @Environment(\.dismiss) private var dismiss

    init(imp: Binding<ImpProfile>, model: AppModel?, tool: ToolEntry, symbol: String, server: String? = nil, preset: [ToolTextRow]? = nil) {
        _imp = imp; self.model = model; self.tool = tool; self.symbol = symbol; self.server = server; self.preset = preset
        _rows = State(initialValue: preset)
    }

    /// The tool as listed. One that is not offered at all (its server is off) has its own name and no default text.
    private var row: ToolTextRow {
        rows?.first { $0.id == tool.id }
            ?? ToolTextRow(id: tool.id, defaultName: tool.name, defaultDescription: "", text: imp.toolText[tool.id], placeholders: [])
    }

    private var problem: ToolTextEditor.NameProblem? {
        ToolTextEditor.nameProblem(name, for: tool.id, among: rows ?? [], texts: imp.toolText)
    }

    var body: some View {
        SheetScaffold(icon: symbol, title: LocalizedStringKey(tool.title.isEmpty ? tool.name : tool.title), width: Sizing.sheetWidth + Spacing.vast) {
            VStack(alignment: .leading, spacing: Spacing.medium) {
                // The id is what the edit is kept under and what switches and rules use: a new name never changes it.
                HStack(spacing: Spacing.snug) {
                    Text("tooltext.id").font(Typeface.small).foregroundStyle(Tone.muted)
                    Text(verbatim: tool.id).font(Typeface.mono).foregroundStyle(Tone.muted).textSelection(.enabled)
                }
                if server != nil, let server { Text(words("tooltext.from_server", server)).font(Typeface.small).foregroundStyle(Tone.muted) }
                nameField
                descriptionField
            }
        } footer: {
            // Puts the default words back in the fields, so you see what the model will read. OK then keeps no edit.
            Button { name = row.defaultName; description = row.defaultDescription } label: {
                FitLabel("tooltext.reset", systemImage: "arrow.counterclockwise")
            }
                .buttonStyle(.quiet)
                .disabled(name == row.defaultName && description == row.defaultDescription)
            Button("common.ok") { save() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(problem != nil || rows == nil)
        }
        .onAppear { fill() }
        .task {
            if rows == nil, let model { rows = await model.toolTextRows(for: imp) }
            fill()
        }
    }

    /// Starts from what the model reads now, in both fields: the Imp's own wording, else the default.
    private func fill() {
        guard !filled, rows != nil else { return }
        filled = true
        let text = imp.toolText[tool.id]
        name = text?.name ?? row.defaultName
        description = text?.description ?? row.defaultDescription
    }

    private func save() {
        var all = imp.toolText
        all[tool.id] = ToolTextEditor.result(name: name, description: description, for: row)
        imp.toolText = all.filter { !$0.value.isEmpty }
        dismiss()
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("tooltext.name").font(Typeface.caption).foregroundStyle(Tone.muted)
            TextField(row.defaultName, text: $name)
                .textFieldStyle(.plain)
                .impField(mono: true, problem: problem.map { $0 == .invalid ? String(localized: "tooltext.name_invalid") : String(localized: "tooltext.name_taken") })
                .accessibilityIdentifier("tool.name")
            if let problem {
                StatusText(text: problem == .invalid ? "tooltext.name_invalid" : "tooltext.name_taken",
                           symbol: "exclamationmark.triangle.fill", color: Tone.danger)
            }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("tooltext.description").font(Typeface.caption).foregroundStyle(Tone.muted)
            EditorWell(text: $description, placeholder: "tooltext.description_empty", height: Sizing.control * 4)
            ForEach(row.placeholders, id: \.self) { key in placeholderRow(key) }
            let dropped = ToolTextEditor.droppedPlaceholders(row, edited: description)
            if !dropped.isEmpty {
                StatusText(text: LocalizedStringKey(words("tooltext.dropped", dropped.map { "{\($0)}" }.joined(separator: " "))),
                           symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
            }
        }
    }

    /// What a placeholder stands for.
    private static func meaning(of key: String) -> LocalizedStringKey {
        switch key {
        case "imps": "tooltext.placeholder.imps"
        case "animations": "tooltext.placeholder.animations"
        default: "tooltext.placeholder.place"
        }
    }

    /// A placeholder this tool can use: tap it to add it at the end of the description, with what it stands for.
    private func placeholderRow(_ key: String) -> some View {
        HStack(spacing: Spacing.small) {
            Button { description += (description.isEmpty || description.hasSuffix(" ") ? "" : " ") + "{\(key)}" } label: {
                Text(verbatim: "{\(key)}").font(Typeface.mono).foregroundStyle(Tone.text)
                    .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
                    .background(Capsule().fill(Tone.card))
            }
            .buttonStyle(.plain).pointerStyle(.link)
            Text(Self.meaning(of: key)).font(Typeface.small).foregroundStyle(Tone.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
