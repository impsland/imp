import AppKit
import ImpKit
import SwiftUI

/// Ready-made extra tools (MCP servers) offered as starting points on the Tools tab.
enum MCPExamples {
    struct Example {
        let server: MCPServerConfig
        let icon: String
        let blurb: LocalizedStringResource

        /// Added in one click, unless it has variables to fill in: then its form opens first.
        var isComplete: Bool { !server.environment.values.contains(where: \.isEmpty) }
    }

    static var examples: [Example] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // dtst servers (npmjs.com/org/dtst) call any OpenAI-compatible API themselves, so they get
        // their own address, key and model: any service, not necessarily the Imp's. `optional`
        // variables may stay blank (dtst treats an empty one as unset).
        func dtst(_ name: String, _ package: String, optional: [String] = []) -> MCPServerConfig {
            var env = ["OPENAI_BASE_URL": "", "OPENAI_API_KEY": "", "OPENAI_MODEL": ""]
            for key in optional { env[key] = "" }
            return MCPServerConfig(name: name, transport: .stdio, command: "npx", arguments: ["-y", package], environment: env)
        }
        return [
            Example(server: MCPServerConfig(name: "Files", transport: .stdio, command: "npx",
                                            arguments: ["-y", "@modelcontextprotocol/server-filesystem", home + "/Documents"]),
                    icon: "folder.fill", blurb: "Files in Documents"),
            Example(server: MCPServerConfig(name: "Memory", transport: .stdio, command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
                    icon: "brain.head.profile", blurb: "Remembers things"),
            Example(server: MCPServerConfig(name: "Fetch", transport: .stdio, command: "uvx", arguments: ["mcp-server-fetch"]),
                    icon: "arrow.down.doc.fill", blurb: "Reads web pages"),
            Example(server: dtst("Images", "@dtst/img"), icon: "photo.fill", blurb: "Makes pictures"),
            Example(server: dtst("Writing", "@dtst/txt"), icon: "text.quote", blurb: "Hands off writing"),
            // Blank voice: the model's first listed voice.
            Example(server: dtst("Speech", "@dtst/tts", optional: ["OPENAI_VOICE"]), icon: "waveform", blurb: "Speaks out loud"),
        ]
    }

    static var all: [MCPServerConfig] { examples.map(\.server) }
}

struct ServerStatus: View {
    let enabled: Bool
    let status: MCPStatus?

    var body: some View {
        let (icon, color, text): (String, Color, String) = switch (enabled, status) {
        case (false, _): ("moon.zzz", .secondary, String(localized: "Starts when an Imp that's out needs it"))
        case (true, .ready(let count, let names)?):
            ("checkmark.circle.fill", .green, names.isEmpty
                ? String(localized: "\(count) tools")
                : String(localized: "\(count) tools: \(names.prefix(6).joined(separator: ", "))"))
        case (true, .failed(let message)?): ("exclamationmark.triangle.fill", .orange, message)
        case (true, _): ("ellipsis.circle", .secondary, String(localized: "Starting…"))
        }
        StatusText(verbatim: text, symbol: icon, color: color)
            .help(text)
    }
}

/// Edits a copy of an extra tool. Nothing reconnects until Save. Paste fills it from a setup
/// snippet (JSON config, command or URL) on the clipboard.
struct ServerEditor: View {
    @State var draft: MCPServerConfig
    let isNew: Bool
    let hub: MCPHub
    let save: (MCPServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var commandLine = ""
    @State private var pairs = ""
    @State private var testing = false
    @State private var result: MCPStatus?
    @State private var pasteFailed = false

    init(draft: MCPServerConfig, isNew: Bool, hub: MCPHub, save: @escaping (MCPServerConfig) -> Void) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.hub = hub
        self.save = save
        _commandLine = State(initialValue: draft.commandLine)
        _pairs = State(initialValue: Self.pairs(of: draft))
    }

    var body: some View {
        SheetScaffold(icon: draft.transport == .stdio ? "terminal.fill" : "globe",
                      title: isNew ? "Add an extra tool" : "Edit “\(draft.name)”",
                      info: "An MCP server, on this Mac or on the web. Paste setup fills the form from a JSON config, command or address you copied from its page.",
                      width: 560) {
            Button { paste() } label: { Label("Paste setup", systemImage: "doc.on.clipboard") }
                .buttonStyle(.imp(.secondary, small: true))
                .help("Fill in from a JSON config, command or address you copied")
        } content: {
            if pasteFailed {
                StatusText(text: "No setup on the clipboard. Copy the JSON, command or address from the tool's page.",
                           symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            VStack(alignment: .leading, spacing: 10) {
                EvenGrid(minWidth: 120, spacing: 6) {
                    ForEach([MCPServerConfig.Transport.stdio, .http], id: \.self) { kind in
                        ChoiceChip(title: kind == .stdio ? "On this Mac" : "On the web",
                                   icon: kind == .stdio ? "terminal.fill" : "globe", picked: draft.transport == kind) {
                            draft.transport = kind
                            pairs = Self.pairs(of: draft)
                            result = nil
                        }
                    }
                }
                FieldRow("Name", width: 92) { TextField("Files", text: $draft.name).impField() }
                if draft.transport == .stdio {
                    FieldRow("Command", width: 92) {
                        TextField("npx -y @modelcontextprotocol/server-memory", text: $commandLine).impField(mono: true)
                    }
                    FieldRow("Variables", info: "KEY=value, one per line. API keys go here.", width: 92) {
                        EditorWell(text: $pairs, codePlaceholder: "API_KEY=…", mono: true, height: 76)
                    }
                } else {
                    FieldRow("Address", width: 92) {
                        TextField(String("https://example.com/mcp"), text: $draft.url).impField(mono: true)
                    }
                    FieldRow("Headers", info: "Name: value, one per line.", width: 92) {
                        EditorWell(text: $pairs, codePlaceholder: "Authorization: Bearer …", mono: true, height: 76)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        } footer: {
            Button("Test") { Task { await test() } }.buttonStyle(.secondary).disabled(testing || !isValid)
            if testing { ProgressView().controlSize(.small) }
            if let result, !testing { ServerStatus(enabled: true, status: result) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(isNew ? "Add" : "Save") { save(applied); dismiss() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
    }

    /// Takes the first server in the clipboard's setup, keeping this one's identity.
    private func paste() {
        guard let found = MCPServerConfig.parse(setup: NSPasteboard.general.string(forType: .string) ?? "").first else {
            withAnimation { pasteFailed = true }
            return
        }
        var next = found
        next.id = draft.id
        draft = next
        commandLine = next.commandLine
        pairs = Self.pairs(of: next)
        result = nil
        withAnimation { pasteFailed = false }
    }

    private static func pairs(of server: MCPServerConfig) -> String {
        server.transport == .stdio ? lines(server.environment, separator: "=") : lines(server.headers, separator: ": ")
    }
    private var applied: MCPServerConfig {
        var c = draft
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.transport == .stdio {
            c.commandLine = commandLine
            c.environment = Self.parse(pairs, separator: "=")
        } else {
            c.url = c.url.trimmingCharacters(in: .whitespaces)
            c.headers = Self.parse(pairs, separator: ":")
        }
        return c
    }

    private var isValid: Bool {
        let c = applied
        guard !c.name.isEmpty else { return false }
        if c.transport == .stdio { return !c.command.isEmpty }
        return URL(string: c.url).flatMap(\.scheme).map { ["http", "https"].contains($0) } ?? false
    }

    private func test() async {
        testing = true
        result = .connecting
        result = await hub.test(applied)
        testing = false
    }

    static func lines(_ dict: [String: String], separator: String) -> String {
        // Address, key, model first (how OpenAI-compatible servers document them), then A to Z.
        let first = ["OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENAI_MODEL"]
        let rank = { (key: String) in first.firstIndex(of: key) ?? first.count }
        return dict.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
            .map { "\($0.key)\(separator)\($0.value)" }.joined(separator: "\n")
    }

    static func parse(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}
