import AppKit
import ImpDesign
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

/// Edits a copy of an extra tool. Nothing reconnects until Save. Paste fills it from a setup
/// snippet (JSON config, command or URL) on the clipboard.
struct ServerEditor: View {
    @State var draft: MCPServerConfig
    let isNew: Bool
    let hub: MCPHub
    let save: (MCPServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var commandLine = ""
    @State private var pairs = ""
    @State private var testState: ActionState = .idle
    @State private var notice: ImpNotice?

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
                      info: "An MCP server, on this Mac or on the web. Paste fills the form from what you copied.",
                      width: Sizing.sheetWidth + Spacing.vast) {
            Button { paste() } label: { FitLabel("Paste setup", systemImage: "doc.on.clipboard") }
                .buttonStyle(.imp(.secondary, small: true))
                .help("Fill in from a JSON config, command or address you copied")
        } content: {
            // A tool's setup is the app's, not one Imp's: say so where it is changed.
            Label("tools.shared_setup", systemImage: SettingScope.everyImp.symbol)
                .font(Typeface.small).foregroundStyle(Tone.muted)
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
                    ForEach([MCPServerConfig.Transport.stdio, .http], id: \.self) { kind in
                        ChoiceChip(title: kind == .stdio ? "On this Mac" : "On the web",
                                   icon: kind == .stdio ? "terminal.fill" : "globe", picked: draft.transport == kind) {
                            draft.transport = kind
                            pairs = Self.pairs(of: draft)
                            testState = .idle
                        }
                    }
                }
                FieldRow("common.name", info: "settings.tool.name.info", width: Sizing.fieldLabel + Spacing.medium) { TextField("Files", text: $draft.name).impField() }
                if draft.transport == .stdio {
                    FieldRow("Command", info: "settings.tool.command.info", width: Sizing.fieldLabel + Spacing.medium) {
                        TextField("npx -y @modelcontextprotocol/server-memory", text: $commandLine).impField(mono: true)
                    }
                    FieldRow("Variables", info: "settings.tool.variables.info", width: Sizing.fieldLabel + Spacing.medium) {
                        EditorWell(text: $pairs, codePlaceholder: "API_KEY=…", mono: true, height: Sizing.control * 2.5)
                    }
                } else {
                    FieldRow("Address", info: "settings.tool.address.info", width: Sizing.fieldLabel + Spacing.medium) {
                        TextField(String("https://example.com/mcp"), text: $draft.url).impField(mono: true)
                    }
                    FieldRow("Headers", info: "settings.tool.headers.info", width: Sizing.fieldLabel + Spacing.medium) {
                        EditorWell(text: $pairs, codePlaceholder: "Authorization: Bearer …", mono: true, height: Sizing.control * 2.5)
                    }
                }
            }
            .padding(Spacing.roomy)
            .impCard(radius: Radius.medium)
        } footer: {
            Button { Task { await test() } } label: { StatefulLabel("Test", symbol: "checkmark.circle", state: testState) }
                .buttonStyle(.secondary).disabled(testState == .working || !isValid)
                .impActionState($testState)
            Spacer()
            Button(isNew ? "Add" : "Save") { save(applied); dismiss() }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .impNotice($notice)
    }

    /// Takes the first server in the clipboard's setup, keeping this one's identity.
    private func paste() {
        guard let found = MCPServerConfig.parse(setup: NSPasteboard.general.string(forType: .string) ?? "").first else {
            notice = .warning(String(localized: "Nothing to paste. Copy the tool's setup first."))
            return
        }
        var next = found
        next.id = draft.id
        draft = next
        commandLine = next.commandLine
        pairs = Self.pairs(of: next)
        testState = .idle
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
        testState = .working
        switch await hub.test(applied) {
        case .ready(let count, let names):
            testState = .done
            notice = .success(names.isEmpty ? String(localized: "\(count) tools")
                              : String(localized: "\(count) tools: \(names.prefix(6).joined(separator: ", "))"))
        case .failed(let message):
            testState = .failed
            notice = .error(message)
        case .connecting:
            testState = .idle
        }
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
