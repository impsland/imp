import ImpKit
import SwiftUI

/// Hatches an Imp on this iPhone, or changes one: a name, a colour, a personality, a brain (an
/// OpenAI-compatible service) and HTTP tool servers. Keys are typed once and go to the Keychain.
/// After that the form only says "Saved".
struct PocketEditor: View {
    let pocket: PocketRuntime
    /// The Imp being changed, or nil for a new one.
    let editing: UUID?
    var done: () -> Void

    private struct ServerDraft: Identifiable {
        var id = UUID()
        var name = ""
        var url = ""
        var header = ""
        /// A new header value. Empty keeps the saved one.
        var value = ""
        /// The host the saved value was meant for.
        var savedFor: String?

        var isBlank: Bool { [name, url, header, value].allSatisfy { $0.trimmed.isEmpty } }
    }

    private static let hues: [Double] = [0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.9]

    @State private var name: String
    @State private var hue: Double
    @State private var personality: String
    @State private var address: String
    @State private var model: String
    @State private var key = ""
    /// The host the saved key was meant for.
    @State private var keyFor: String?
    @State private var servers: [ServerDraft]
    @State private var toolsOpen = false
    @State private var confirmingDelete = false
    private let look: LinkImp

    init(pocket: PocketRuntime, editing: UUID?, done: @escaping () -> Void) {
        self.pocket = pocket
        self.editing = editing
        self.done = done
        let imp = editing.flatMap { id in pocket.imps.first { $0.id == id } }
        let secrets = pocket.secrets
        _name = State(initialValue: imp?.name ?? ImpProfile.randomName(avoiding: pocket.imps.map(\.name)))
        _hue = State(initialValue: imp?.hue ?? Self.hues.randomElement() ?? 0)
        _personality = State(initialValue: imp.map { $0.personality == Persona.pocket(named: $0.name) ? "" : $0.personality } ?? "")
        _address = State(initialValue: imp?.brain.baseURL ?? "")
        _model = State(initialValue: imp?.brain.model ?? "")
        _keyFor = State(initialValue: imp.flatMap { secrets.get(.apiKey, imp: $0.id) != nil ? Self.host($0.brain.baseURL) : nil })
        _servers = State(initialValue: imp?.servers.map { server in
            ServerDraft(id: server.id, name: server.name, url: server.url, header: server.header ?? "",
                        savedFor: imp.flatMap { secrets.get(.header(server.id), imp: $0.id) != nil ? Self.host(server.url) : nil })
        } ?? [])
        look = LinkImp(id: imp?.id ?? UUID(), name: "", hue: 0, scale: imp?.scale ?? 1, traits: imp?.traits ?? .plain)
    }

    var body: some View {
        NavigationStack {
            Form {
                preview
                Section("Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    if let problem = nameProblem { Problem(text: problem) }
                }
                .listRowBackground(Dungeon.card)
                Section("Color") { swatches }
                    .listRowBackground(Dungeon.card)
                Section("Personality") {
                    TextField("Optional: how it talks and what it likes", text: $personality, axis: .vertical)
                        .lineLimit(2...5)
                }
                .listRowBackground(Dungeon.card)
                brainSection
                toolsSection
                if editing != nil {
                    Section {
                        Button("Delete Imp", role: .destructive) { confirmingDelete = true }
                    }
                    .listRowBackground(Dungeon.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Dungeon.deep)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editing == nil ? "Hatch an Imp" : "Edit Imp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Hatch" : "Save", action: save).disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(name.trimmed)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { pocket.delete(editing) }
                    done()
                }
            } message: {
                Text("Its chats and keys are forgotten. This can't be undone.")
            }
        }
    }

    // MARK: Sections

    private var preview: some View {
        LiveImp(imp: LinkImp(id: look.id, name: name, hue: hue, scale: look.scale, traits: look.traits))
            .frame(width: 120, height: 120)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityHidden(true)
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(Self.hues, id: \.self) { value in
                let chosen = abs(hue - value) < 0.01
                Button { hue = value } label: {
                    Circle().fill(Color.imp(value))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Dungeon.cream, lineWidth: chosen ? 2.5 : 0).padding(-4))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var brainSection: some View {
        Section {
            field("Address") {
                TextField("Address", text: $address, prompt: Text(verbatim: "https://api.openai.com/v1"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let problem = addressProblem { Problem(text: problem) }
            field("Key") {
                SecureField("Key", text: $key, prompt: Text(keyKept ? LocalizedStringKey("Saved") : "Paste your API key"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if keyKept && key.isEmpty {
                Button("Remove saved key", role: .destructive) { keyFor = nil }
            }
            field("Model") {
                TextField("Model", text: $model, prompt: Text(verbatim: "gpt-4o-mini"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let problem = modelProblem { Problem(text: problem) }
        } header: {
            Text("Brain")
        } footer: {
            Text("Your key stays in this iPhone's Keychain.")
        }
        .listRowBackground(Dungeon.card)
    }

    private var toolsSection: some View {
        Section {
            DisclosureGroup("Tools (optional)", isExpanded: $toolsOpen) {
                ForEach($servers) { $server in
                    serverFields($server)
                }
                Button { servers.append(ServerDraft()) } label: { Label("Add a tool server", systemImage: "plus") }
                    .disabled(servers.count >= PocketImp.maxServers)
                Text("Web (HTTP) servers that speak MCP. Header values stay in this iPhone's Keychain.")
                    .font(.footnote).foregroundStyle(Dungeon.muted)
            }
        }
        .listRowBackground(Dungeon.card)
    }

    private func serverFields(_ server: Binding<ServerDraft>) -> some View {
        let value = server.wrappedValue
        let kept = value.savedFor != nil && value.savedFor == Self.host(value.url)
        return VStack(alignment: .leading, spacing: 6) {
            field("Name") { TextField("Name", text: server.name, prompt: Text("Optional")) }
            field("URL") {
                TextField("URL", text: server.url, prompt: Text(verbatim: "https://example.com/mcp"))
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if let problem = serverProblem(value) { Problem(text: problem) }
            field("Header") {
                TextField("Header", text: server.header, prompt: Text(verbatim: "Authorization"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            field("Value") {
                SecureField("Value", text: server.value, prompt: Text(kept ? LocalizedStringKey("Saved") : "Optional"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("Remove", role: .destructive) { servers.removeAll { $0.id == value.id } }
                .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        LabeledContent(title) { content().multilineTextAlignment(.trailing) }
    }

    // MARK: Checking

    private var keyKept: Bool { keyFor != nil && keyFor == Self.host(address) }

    private var nameProblem: String? {
        name.trimmed.count > PocketImp.maxName ? PocketError.badName.errorDescription : nil
    }

    private var hasBrain: Bool { !address.trimmed.isEmpty || !model.trimmed.isEmpty }

    private var addressProblem: String? {
        if address.trimmed.isEmpty { return hasBrain ? PocketError.noBrain.errorDescription : nil }
        return Self.problem { try PocketImp.check(url: address) }
    }

    private var modelProblem: String? {
        model.trimmed.isEmpty && !address.trimmed.isEmpty ? PocketError.noBrain.errorDescription : nil
    }

    private func serverProblem(_ server: ServerDraft) -> String? {
        server.url.trimmed.isEmpty && !server.isBlank ? PocketError.badURL("").errorDescription : Self.problem { try PocketImp.check(url: server.url) }
    }

    private var canSave: Bool {
        guard !name.trimmed.isEmpty, nameProblem == nil, addressProblem == nil, modelProblem == nil else { return false }
        return servers.allSatisfy { $0.isBlank || serverProblem($0) == nil }
    }

    private static func problem(_ check: () throws -> Void) -> String? {
        do { try check(); return nil } catch { return error.localizedDescription }
    }

    /// Where an address leads. A secret saved for one place isn't sent to another.
    private static func host(_ address: String) -> String? {
        URL(string: address.trimmed)?.host()?.lowercased()
    }

    // MARK: Saving

    private func save() {
        guard canSave else { return }
        let service = PocketService(baseURL: address.trimmed, model: model.trimmed)
        let made = servers.filter { !$0.isBlank }.map { draft in
            let url = draft.url.trimmed
            let kept = draft.savedFor != nil && draft.savedFor == Self.host(url)
            let hasValue = !draft.value.isEmpty || kept
            let server = PocketServer(id: draft.id, name: draft.name.trimmed.isEmpty ? Self.host(url) ?? url : draft.name.trimmed, url: url,
                                      header: hasValue ? (draft.header.trimmed.isEmpty ? "Authorization" : draft.header.trimmed) : nil)
            return (draft, server)
        }
        let id = editing ?? look.id
        let words = personality.trimmed.isEmpty ? Persona.pocket(named: name.trimmed) : personality.trimmed
        if editing == nil {
            pocket.hatch(PocketImp(id: id, name: name.trimmed, hue: hue, traits: look.traits, personality: words, brain: service, servers: made.map(\.1)))
        } else {
            pocket.edit(id) { imp in
                imp.name = name.trimmed
                imp.hue = hue
                imp.personality = words
                imp.brain = service
                imp.servers = made.map(\.1)
            }
        }
        let secrets = pocket.secrets
        if !key.isEmpty { secrets.set(key, .apiKey, imp: id) }
        else if !keyKept { secrets.remove(.apiKey, imp: id) }
        for (draft, server) in made {
            if !draft.value.isEmpty { secrets.set(draft.value, .header(server.id), imp: id) }
            else if server.header == nil { secrets.remove(.header(server.id), imp: id) }
        }
        done()
    }
}

/// Why a field can't be used yet.
private struct Problem: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(Dungeon.flame)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
