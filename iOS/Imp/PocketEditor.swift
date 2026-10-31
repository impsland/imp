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
    /// The sizes the Mac offers too.
    private static let sizes: [(name: LocalizedStringKey, scale: Double)] = [("Small", 0.75), ("Medium", 1), ("Large", 1.35), ("Huge", 1.7)]

    private enum Field: Hashable { case name, personality, address, key, model }

    @State private var name: String
    @State private var hue: Double
    @State private var scale: Double
    @State private var personality: String
    @State private var address: String
    @State private var model: String
    @State private var key = ""
    /// The host the saved key was meant for.
    @State private var keyFor: String?
    @State private var servers: [ServerDraft]
    @State private var toolsOpen = false
    @State private var confirmingDelete = false
    /// The tool server asked to be removed, while its saved value is being confirmed.
    @State private var removing: UUID?
    @State private var choosingModel = false
    @FocusState private var focus: Field?
    @Environment(\.openURL) private var openURL
    private let look: LinkImp

    init(pocket: PocketRuntime, editing: UUID?, done: @escaping () -> Void) {
        self.pocket = pocket
        self.editing = editing
        self.done = done
        let imp = editing.flatMap { id in pocket.imps.first { $0.id == id } }
        let secrets = pocket.secrets
        _name = State(initialValue: imp?.name ?? ImpProfile.randomName(avoiding: pocket.imps.map(\.name)))
        _hue = State(initialValue: imp?.hue ?? Self.hues.randomElement() ?? 0)
        _scale = State(initialValue: Self.sizes.min { abs($0.scale - (imp?.scale ?? 1)) < abs($1.scale - (imp?.scale ?? 1)) }?.scale ?? 1)
        _personality = State(initialValue: imp.map { $0.personality == Persona.pocket(named: $0.name) ? "" : $0.personality } ?? "")
        _address = State(initialValue: imp?.brain.baseURL ?? "")
        _model = State(initialValue: imp?.brain.model ?? "")
        _keyFor = State(initialValue: imp.flatMap { secrets.get(.apiKey, imp: $0.id) != nil ? Self.host($0.brain.baseURL) : nil })
        _servers = State(initialValue: imp?.servers.map { server in
            ServerDraft(id: server.id, name: server.name, url: server.url, header: server.header ?? "",
                        savedFor: imp.flatMap { secrets.get(.header(server.id), imp: $0.id) != nil ? Self.host(server.url) : nil })
        } ?? [])
        look = LinkImp(id: imp?.id ?? UUID(), name: "", hue: 0, scale: 1, traits: imp?.traits ?? .plain)
    }

    var body: some View {
        NavigationStack {
            Form {
                preview
                Section {
                    HStack {
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .personality }
                        if let problem = nameProblem { IssueBadge(text: problem) }
                    }
                    TextField("Optional: how it talks and what it likes", text: $personality, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focus, equals: .personality)
                        .submitLabel(.next)
                        // One paragraph: Return moves on instead of starting a new line.
                        .onChange(of: personality) { _, text in
                            guard text.contains("\n") else { return }
                            personality = text.replacingOccurrences(of: "\n", with: "")
                            focus = .address
                        }
                } header: {
                    Text("Imp")
                } footer: {
                    Text("Leave the personality empty for a friendly default.")
                }
                .listRowBackground(Dungeon.card)
                Section("Look") {
                    swatches
                    Picker("Size", selection: $scale) {
                        ForEach(Self.sizes, id: \.scale) { Text($0.name).tag($0.scale) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Dungeon.card)
                brainSection
                toolsSection
                if editing != nil {
                    Section {
                        // The dialog hangs on the button: two on the same view and only one ever shows.
                        Button("Delete Imp", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete \(name.trimmed)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                Button("Delete", role: .destructive) {
                                    if let editing { pocket.delete(editing) }
                                    done()
                                }
                            } message: {
                                Text("Its chats and keys are forgotten. This can't be undone.")
                            }
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
            .confirmationDialog("Remove this tool server?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    withAnimation { servers.removeAll { $0.id == removing } }
                    removing = nil
                }
            } message: {
                Text("Its saved header value is forgotten.")
            }
            .sheet(isPresented: $choosingModel) {
                ModelPicker(address: address.trimmed, key: keyToTry) { model = $0 }
            }
        }
    }

    // MARK: Imp

    private var preview: some View {
        LiveImp(imp: LinkImp(id: look.id, name: name, hue: hue, scale: scale, traits: look.traits))
            .frame(width: 100 * scale, height: 100 * scale)
            .frame(maxWidth: .infinity, minHeight: 180)
            .animation(.spring(duration: 0.4, bounce: 0.3), value: scale)
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

    // MARK: Brain

    private var brainSection: some View {
        Section {
            if !hasBrain {
                Label("No brain yet: it sleeps until you give it one.", systemImage: "moon.zzz")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            }
            presetChips
            field("Address") {
                HStack(spacing: 4) {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://openrouter.ai/api/v1"))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .key }
                    if let problem = addressProblem { IssueBadge(text: problem) }
                    else if let hint = localHint { IssueBadge(text: hint, kind: .info) }
                }
            }
            field("Key") {
                SecureField("Key", text: $key, prompt: Text(keyKept ? LocalizedStringKey("Saved") : (matched?.isLocal == true ? "Not needed" : "Paste your API key")))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .key)
                    .submitLabel(.next)
                    .onSubmit { focus = .model }
            }
            if keyKept && key.isEmpty {
                Button("Remove saved key", role: .destructive) { keyFor = nil }
            }
            field("Model") {
                HStack(spacing: 8) {
                    TextField("Model", text: $model, prompt: Text(verbatim: "openai/gpt-6-luna"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .model)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                    if let problem = modelProblem { IssueBadge(text: problem) }
                    Button("Choose") { focus = nil; choosingModel = true }
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .buttonStyle(.borderless)
                        .foregroundStyle(Dungeon.flame)
                        .disabled(address.trimmed.isEmpty || addressProblem != nil)
                }
            }
        } header: {
            Text("Brain")
        } footer: {
            Text("An OpenAI-compatible service. Your key stays in this iPhone's Keychain.")
        }
        .listRowBackground(Dungeon.card)
    }

    /// One chip per well-known service: the name fills the address, the arrow opens where to get started.
    private var presetChips: some View {
        Wrap(spacing: 8) {
            ForEach(ServicePreset.phone) { preset in
                let picked = matched == preset
                HStack(spacing: 0) {
                    Button { choose(preset) } label: {
                        Text(verbatim: preset.name)
                            .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    Button { openURL(preset.link) } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(preset.name)'s page")
                }
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(picked ? Dungeon.deep : Dungeon.cream)
                .background(picked ? AnyShapeStyle(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom))
                                   : AnyShapeStyle(Dungeon.card), in: Capsule())
                .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
            }
        }
        .padding(.vertical, 2)
    }

    private var matched: ServicePreset? { ServicePreset.matching(address) }

    /// A service on your Mac is reached by the Mac's name on your network (`.local`, which follows
    /// the Mac when its Wi-Fi address changes), else its address, both from the pairing. Without a
    /// pairing there's a name to replace.
    private func choose(_ preset: ServicePreset) {
        withAnimation(.snappy) {
            address = preset.isLocal ? preset.baseURL(onHost: pocket.macHost ?? Self.yourMac) : preset.baseURL
        }
        focus = preset.isLocal ? .model : .key
    }

    /// Stands in for the Mac's name until you put it there.
    private static let yourMac = "your-mac.local"

    /// What a service on your computer needs before the iPhone can reach it.
    private var localHint: String? {
        guard matched?.isLocal == true else { return nil }
        return String(localized: "The server has to listen on the network, not just on localhost.")
    }

    /// The key to list models with: what's typed, or the one kept in the Keychain.
    private var keyToTry: String {
        if !key.isEmpty { return key }
        guard keyKept, let editing else { return "" }
        return pocket.secrets.get(.apiKey, imp: editing) ?? ""
    }

    // MARK: Tools

    private var toolsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $toolsOpen) {
                Text("Tools let your Imp reach things beyond chat: a web (HTTP) MCP server it can call to search, fetch or do things for you.")
                    .font(.footnote).foregroundStyle(Dungeon.muted)
            } label: {
                HStack {
                    Text("Tools")
                    Text("Optional").font(.footnote).foregroundStyle(Dungeon.muted)
                    Spacer()
                    if toolsBroken && !toolsOpen {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Dungeon.flame)
                            .accessibilityLabel("Needs attention")
                    }
                    let count = servers.filter { !$0.isBlank }.count
                    if count > 0 && !toolsOpen {
                        Text("\(count)")
                            .font(.system(.footnote, design: .rounded, weight: .bold))
                            .foregroundStyle(Dungeon.deep)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Dungeon.ember, in: Capsule())
                    }
                }
            }
            if toolsOpen {
                ForEach($servers) { $server in
                    serverCard($server)
                }
                Button { addServer() } label: { Label("Add a tool server", systemImage: "plus.circle.fill") }
                    .disabled(servers.count >= PocketImp.maxServers)
                    .foregroundStyle(servers.count >= PocketImp.maxServers ? Dungeon.muted : Dungeon.flame)
            }
        } footer: {
            if toolsOpen { Text("Up to \(PocketImp.maxServers) servers. Header values stay in this iPhone's Keychain.") }
        }
        .listRowBackground(Dungeon.card)
    }

    private var toolsBroken: Bool { servers.contains { !$0.isBlank && serverProblem($0) != nil } }

    private func addServer() {
        let draft = ServerDraft()
        withAnimation { servers.append(draft) }
    }

    private func serverCard(_ server: Binding<ServerDraft>) -> some View {
        let value = server.wrappedValue
        let kept = value.savedFor != nil && value.savedFor == Self.host(value.url)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Dungeon.ember)
                Text(value.name.trimmed.isEmpty ? (Self.host(value.url) ?? String(localized: "New tool server")) : value.name.trimmed)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(role: .destructive) { remove(value) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove tool server")
            }
            field("Name") { TextField("Name", text: server.name, prompt: Text("Optional")) }
            field("URL") {
                HStack(spacing: 4) {
                    TextField("URL", text: server.url, prompt: Text(verbatim: "https://example.com/mcp"))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let problem = serverProblem(value) { IssueBadge(text: problem) }
                }
            }
            Divider().overlay(Dungeon.cardEdge)
            Text("Authorization header (optional)")
                .font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.muted)
            field("Header") {
                TextField("Header", text: server.header, prompt: Text(verbatim: "Authorization"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            field("Value") {
                SecureField("Value", text: server.value, prompt: Text(kept ? LocalizedStringKey("Saved") : "Token or key"))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .padding(.vertical, 4)
    }

    private func remove(_ server: ServerDraft) {
        let kept = server.savedFor != nil && server.savedFor == Self.host(server.url)
        if kept || !server.value.isEmpty { removing = server.id }
        else { withAnimation { servers.removeAll { $0.id == server.id } } }
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
        if address.trimmed.isEmpty { return hasBrain ? String(localized: "Add the service's address.") : nil }
        if Self.host(address) == Self.yourMac {
            return String(localized: "Put your Mac's name in place of your-mac.local (System Settings › General › Sharing), or its Wi-Fi address. Or pair your Mac and pick the preset again.")
        }
        if let host = Self.host(address), host == "localhost" || host == "127.0.0.1" {
            return String(localized: "On your iPhone, use your Mac's name or address instead of localhost.")
        }
        return Self.problem { try PocketImp.check(url: address) }
    }

    private var modelProblem: String? {
        model.trimmed.isEmpty && !address.trimmed.isEmpty ? String(localized: "Pick a model, or type its name.") : nil
    }

    /// A card you haven't filled in yet is fine (it's left out); one with something in it needs its address.
    private func serverProblem(_ server: ServerDraft) -> String? {
        if server.isBlank { return nil }
        if server.url.trimmed.isEmpty { return String(localized: "Add the server's address.") }
        return Self.problem { try PocketImp.check(url: server.url) }
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
        let service = PocketService(baseURL: address.trimmed, model: model.trimmed, name: address.trimmed.isEmpty ? nil : matched?.name)
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
            pocket.hatch(PocketImp(id: id, name: name.trimmed, hue: hue, scale: scale, traits: look.traits, personality: words, brain: service, servers: made.map(\.1)))
        } else {
            pocket.edit(id) { imp in
                imp.name = name.trimmed
                imp.hue = hue
                imp.scale = scale
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

/// Lays chips out in rows, wrapping to the next line when they don't fit.
private struct Wrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews)
        for (view, origin) in zip(subviews, laid.origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + row), origins)
    }
}

/// The service's models, to pick one instead of typing its name.
private struct ModelPicker: View {
    let address: String
    let key: String
    var pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [String]?
    @State private var failure: String?
    @State private var query = ""

    private var shown: [String] {
        let q = query.trimmed
        return (models ?? []).filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let failure {
                    ContentUnavailableView {
                        Label("Couldn't list the models", systemImage: "exclamationmark.circle")
                    } description: {
                        IssueBadge(text: failure)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if models == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No models found" : "No match", systemImage: "magnifyingglass")
                } else {
                    List(shown, id: \.self) { id in
                        Button { pick(id); dismiss() } label: { Text(verbatim: id).foregroundStyle(Dungeon.cream) }
                            .listRowBackground(Dungeon.card)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Dungeon.deep)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .textInputAutocapitalization(.never)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        models = nil
        do {
            models = try await OpenAIClient(baseURL: address, apiKey: key).models()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
