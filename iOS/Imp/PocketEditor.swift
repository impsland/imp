import ImpDesign
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

    private struct HeaderDraft: Identifiable {
        var id = UUID()
        var name = ""
        /// A new value. Empty keeps the saved one.
        var value = ""
        /// The name the saved value was kept under, if there is one.
        var savedName: String?

        var isBlank: Bool { name.trimmed.isEmpty && value.isEmpty }
    }

    private struct ServerDraft: Identifiable {
        var id = UUID()
        var name = ""
        var url = ""
        var headers: [HeaderDraft] = []
        /// The host the saved values were meant for.
        var savedFor: String?

        var isBlank: Bool { name.trimmed.isEmpty && url.trimmed.isEmpty && headers.allSatisfy(\.isBlank) }
        var holdsSecrets: Bool { headers.contains { $0.savedName != nil || !$0.value.isEmpty } }
    }

    private static let hues: [Double] = [0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.9]
    /// The sizes the Mac offers too.
    private static let sizes: [(name: String, scale: Double)] = [
        (String(localized: "Small"), 0.75), (String(localized: "Medium"), 1), (String(localized: "Large"), 1.35), (String(localized: "Huge"), 1.7),
    ]
    /// The size a new Imp starts with.
    private static let newSize = 1.7

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saveProblem: String?
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
        _scale = State(initialValue: Self.sizes.min { abs($0.scale - (imp?.scale ?? Self.newSize)) < abs($1.scale - (imp?.scale ?? Self.newSize)) }?.scale ?? Self.newSize)
        _personality = State(initialValue: imp.map { $0.personality == Persona.pocket(named: $0.name) ? "" : $0.personality } ?? "")
        _address = State(initialValue: imp?.brain.baseURL ?? "")
        _model = State(initialValue: imp?.brain.model ?? "")
        _keyFor = State(initialValue: imp.flatMap { secrets.get(.apiKey, imp: $0.id) != nil ? Self.host($0.brain.baseURL) : nil })
        _servers = State(initialValue: imp?.servers.map { server -> ServerDraft in
            let heads = server.headers.map { name in
                HeaderDraft(name: name, savedName: imp.flatMap { secrets.get(.header(server.id, name), imp: $0.id) != nil ? name : nil })
            }
            return ServerDraft(id: server.id, name: server.name, url: server.url, headers: heads,
                               savedFor: heads.contains { $0.savedName != nil } ? Self.host(server.url) : nil)
        } ?? [])
        look = LinkImp(id: imp?.id ?? UUID(), name: "", hue: 0, scale: 1, traits: imp?.traits ?? .plain)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Spacing.medium) {
                        preview
                        impCard
                        lookCard
                        brainCard
                        toolsCard(proxy)
                        if editing != nil { deleteButton }
                    }
                    .padding(.horizontal, Spacing.large)
                    .padding(.vertical, Spacing.medium)
                }
                // Dragging or tapping empty space puts the keyboard away. Buttons and fields keep their taps.
                .dismissesKeyboard()
                .keyboardGap()
            }
            .impControls(tint: Dungeon.ember)
            .background(Dungeon.deep)
            .navigationTitle(editing == nil ? "Hatch an Imp" : "Edit Imp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The navigation bar keeps the system's buttons: they sit in system chrome, which sizes,
                // tints and reads them to VoiceOver by itself.
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done).buttonStyle(.automatic) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Hatch" : "Save", action: save).buttonStyle(.automatic).disabled(!canSave)
                }
            }
            .confirmationDialog("Remove this tool server?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    withImpAnimation(reduceMotion: reduceMotion) { servers.removeAll { $0.id == removing } }
                    removing = nil
                }
            } message: {
                Text("Its saved header values are forgotten.")
            }
            .alert("Couldn't save", isPresented: Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveProblem ?? "")
            }
            .sheet(isPresented: $choosingModel) {
                ModelPicker(address: address.trimmed, key: keyToTry) { model = $0 }
            }
        }
        .tipHost()
    }

    /// After a section opens or grows: scrolls so the new part is on screen, once the animation has run.
    private func reveal(_ proxy: ScrollViewProxy, _ id: some Hashable, anchor: UnitPoint) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 320))
            withImpAnimation(.smooth, reduceMotion: reduceMotion) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    private var deleteButton: some View {
        // The dialog hangs on the button: two on the same view and only one ever shows.
        Button { confirmingDelete = true } label: { Label("Delete Imp", systemImage: "trash") }
            .buttonStyle(.destructive)
            .frame(maxWidth: .infinity)
            .confirmationDialog("Delete \(name.trimmed)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { pocket.delete(editing) }
                    done()
                }
            } message: {
                Text("Its chats and keys are forgotten. This can't be undone.")
            }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Typeface.caption).foregroundStyle(Dungeon.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Imp

    private var impCard: some View {
        Card("Imp") {
            field("Name") {
                HStack(spacing: 4) {
                    TextField("Name", text: $name)
                        .impField()
                        .textInputAutocapitalization(.words)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .personality }
                    if let problem = nameProblem { IssueBadge(text: problem) }
                }
            }
            field("Personality") {
                TextArea("Personality", text: $personality, placeholder: "How it talks and what it likes", minLines: 3, maxLines: 8)
                    .focused($focus, equals: .personality)
                    .submitLabel(.next)
                    // One paragraph: Return moves on instead of starting a new line.
                    .onChange(of: personality) { _, text in
                        guard text.contains("\n") else { return }
                        personality = text.replacingOccurrences(of: "\n", with: "")
                        focus = .address
                    }
            }
            note("Leave the personality empty for a friendly default.")
        }
    }

    private var lookCard: some View {
        Card("Look") {
            swatches
            ImpSegmented("Size", selection: $scale, options: Self.sizes.map(\.scale)) { value in
                Self.sizes.first { $0.scale == value }?.name ?? ""
            }
        }
    }

    private var preview: some View {
        // The same Imp as on the first screen: it leans and looks the way the phone tips.
        TiltImp(imp: LinkImp(id: look.id, name: name, hue: hue, scale: scale, traits: look.traits), interactive: false)
            .frame(width: 100 * scale, height: 100 * scale)
            .frame(maxWidth: .infinity, minHeight: 180)
            .impAnimation(.spring(duration: 0.4, bounce: 0.3), value: scale)
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
                        .frame(maxWidth: .infinity, minHeight: Sizing.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Color")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    // MARK: Brain

    private var brainCard: some View {
        Card("Brain") {
            if !hasBrain {
                Label("No brain yet: it sleeps until you give it one.", systemImage: "moon.zzz")
                    .font(Typeface.caption).foregroundStyle(Dungeon.muted)
            }
            presetChips
            field("Address") {
                HStack(spacing: 4) {
                    TextField("Address", text: $address, prompt: Text(verbatim: "https://openrouter.ai/api/v1"))
                        .impField(mono: true)
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
                    .impField(mono: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .key)
                    .submitLabel(.next)
                    .onSubmit { focus = .model }
            }
            if keyKept && key.isEmpty {
                Button { keyFor = nil } label: { Label("Remove saved key", systemImage: "key.slash") }
                    .buttonStyle(.destructive)
            }
            field("Model") {
                // One well: the Choose button sits inside the field, so the shapes match.
                HStack(spacing: 6) {
                    TextField("Model", text: $model, prompt: Text(verbatim: "openai/gpt-6-luna"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .model)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                    if let problem = modelProblem { IssueBadge(text: problem) }
                    let canChoose = !(address.trimmed.isEmpty || addressProblem != nil)
                    Button { focus = nil; choosingModel = true } label: {
                        Text("Choose").font(Typeface.label)
                            .foregroundStyle(canChoose ? Dungeon.ember : Dungeon.muted)
                            .padding(.leading, 10)
                            .frame(minHeight: Sizing.hit)
                            .overlay(alignment: .leading) { Rectangle().fill(Dungeon.cardEdge).frame(width: 1).padding(.vertical, 8) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canChoose)
                }
                .impField(mono: true)
            }
            note("An OpenAI-compatible service. Your key stays in this iPhone's Keychain.")
        }
    }

    /// One chip per well-known service: the name fills the address, the arrow opens where to get started.
    private var presetChips: some View {
        Wrap(spacing: 8) {
            ForEach(ServicePreset.phone) { preset in
                let picked = matched == preset
                HStack(spacing: 0) {
                    Button { choose(preset) } label: {
                        Text(verbatim: preset.name)
                            .padding(.leading, 12).padding(.trailing, 4)
                            .frame(minHeight: Sizing.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    Button { openURL(preset.link) } label: {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                            .padding(.leading, 4).padding(.trailing, 12)
                            .frame(minHeight: Sizing.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(preset.name)'s page")
                }
                // The same look as `ChoiceChip`, split in two so the arrow can open the service's page.
                .font(Typeface.label)
                .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.9))
                .background(picked ? AnyShapeStyle(Dungeon.ember.gradient) : AnyShapeStyle(Color.white.opacity(0.06)), in: Capsule())
                .overlay(Capsule().strokeBorder(picked ? Color.white.opacity(0.2) : Dungeon.cardEdge))
            }
        }
        .padding(.vertical, 2)
    }

    private var matched: ServicePreset? { ServicePreset.matching(address) }

    /// A service on your Mac is reached by the Mac's name on your network (`.local`, which follows
    /// the Mac when its Wi-Fi address changes), else its address, both from the link. Without a
    /// linked Mac there's a name to replace.
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

    private func toolsCard(_ proxy: ScrollViewProxy) -> some View {
        Card {
            Button {
                withImpAnimation(Timing.smooth, reduceMotion: reduceMotion) { toolsOpen.toggle() }
                if toolsOpen { reveal(proxy, "tools", anchor: .top) }
            } label: {
                HStack(spacing: 8) {
                    Text("Tools").font(Typeface.cardTitle).foregroundStyle(Dungeon.cream)
                    Text("Optional").font(Typeface.caption).foregroundStyle(Dungeon.muted)
                    Spacer()
                    if toolsBroken && !toolsOpen {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Dungeon.flame)
                            .accessibilityLabel("Needs attention")
                    }
                    let count = servers.filter { !$0.isBlank }.count
                    if count > 0 && !toolsOpen {
                        Text("\(count)")
                            .font(Typeface.small.weight(.bold))
                            .foregroundStyle(Dungeon.deep)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Dungeon.ember, in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Dungeon.muted)
                        .rotationEffect(.degrees(toolsOpen ? 90 : 0))
                }
                .frame(minHeight: Sizing.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(toolsOpen ? Text("Open") : Text("Closed"))
            if toolsOpen {
                note("Tools let your Imp reach things beyond chat: a web (HTTP) MCP server it can call to search, fetch or do things for you.")
                ForEach($servers) { $server in
                    serverCard($server, proxy)
                }
                Button { addServer(proxy) } label: { Label("Add a tool server", systemImage: "plus") }
                    .buttonStyle(.secondary)
                    .disabled(servers.count >= PocketImp.maxServers)
                note("Up to \(PocketImp.maxServers) servers. Header values stay in this iPhone's Keychain.")
            }
        }
        .id("tools")
    }

    private var toolsBroken: Bool { servers.contains { !$0.isBlank && serverProblem($0) != nil } }

    private func addServer(_ proxy: ScrollViewProxy) {
        let draft = ServerDraft()
        withImpAnimation(reduceMotion: reduceMotion) { servers.append(draft) }
        reveal(proxy, draft.id, anchor: .top)
    }

    private func addHeader(_ server: Binding<ServerDraft>, _ proxy: ScrollViewProxy) {
        let draft = HeaderDraft()
        withImpAnimation(reduceMotion: reduceMotion) { server.wrappedValue.headers.append(draft) }
        reveal(proxy, draft.id, anchor: .center)
    }

    private func serverCard(_ server: Binding<ServerDraft>, _ proxy: ScrollViewProxy) -> some View {
        let value = server.wrappedValue
        let hostKept = value.savedFor != nil && value.savedFor == Self.host(value.url)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Dungeon.ember)
                Text(value.name.trimmed.isEmpty ? (Self.host(value.url) ?? String(localized: "New tool server")) : value.name.trimmed)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { remove(value) } label: { Image(systemName: "trash") }
                    .buttonStyle(.destructive)
                    .accessibilityLabel("Remove tool server")
            }
            field("Name") { TextField("Name", text: server.name, prompt: Text("Optional")).impField() }
            field("URL") {
                HStack(spacing: 4) {
                    TextField("URL", text: server.url, prompt: Text(verbatim: "https://example.com/mcp"))
                        .impField(mono: true)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let problem = serverProblem(value) { IssueBadge(text: problem) }
                }
            }
            CardDivider()
            Text("Headers (optional)")
                .font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.muted)
            ForEach(server.headers) { $header in
                let kept = hostKept && header.savedName != nil
                VStack(alignment: .leading, spacing: Spacing.small) {
                    HStack(spacing: Spacing.small) {
                        TextField("Header", text: $header.name, prompt: Text(verbatim: "Authorization"))
                            .impField(mono: true)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { removeHeader(header.id, from: server) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.quiet)
                            .accessibilityLabel("Remove header")
                    }
                    SecureField("Value", text: $header.value, prompt: kept ? Text("Saved") : Text(verbatim: "Bearer …"))
                        .impField(mono: true)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .id(header.id)
            }
            Button { addHeader(server, proxy) } label: { Label("Add a header", systemImage: "plus") }
                .buttonStyle(.imp(.secondary, small: true))
                .disabled(value.headers.count >= PocketServer.maxHeaders)
        }
        .padding(12)
        .impCard(radius: Radius.medium)
        .id(value.id)
    }

    private func removeHeader(_ id: UUID, from server: Binding<ServerDraft>) {
        withImpAnimation(reduceMotion: reduceMotion) { server.wrappedValue.headers.removeAll { $0.id == id } }
    }

    private func remove(_ server: ServerDraft) {
        let kept = server.savedFor != nil && server.savedFor == Self.host(server.url)
        if (kept && server.holdsSecrets) || server.headers.contains(where: { !$0.value.isEmpty }) { removing = server.id }
        else { withImpAnimation(reduceMotion: reduceMotion) { servers.removeAll { $0.id == server.id } } }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(Typeface.caption).foregroundStyle(Dungeon.muted)
            content()
        }
        .padding(.vertical, Spacing.tight)
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
            return String(localized: "Put your Mac's name in place of your-mac.local (System Settings › General › Sharing), or its Wi-Fi address. Or link your Mac and pick the preset again.")
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
        /// A header to keep: its name and the value to store now, or the saved one under `from`.
        struct Plan { var name: String; var typed: String; var from: String? }
        let id = editing ?? look.id
        let made: [(ServerDraft, PocketServer, [Plan])] = servers.filter { !$0.isBlank }.map { draft in
            let url = draft.url.trimmed
            let hostKept = draft.savedFor != nil && draft.savedFor == Self.host(url)
            var seen: Set<String> = []
            var plans: [Plan] = []
            for header in draft.headers {
                let kept = hostKept && header.savedName != nil
                guard !header.value.isEmpty || kept else { continue }
                let name = header.name.trimmed.isEmpty ? "Authorization" : header.name.trimmed
                guard plans.count < PocketServer.maxHeaders, seen.insert(name.lowercased()).inserted else { continue }
                plans.append(Plan(name: name, typed: header.value, from: kept ? header.savedName : nil))
            }
            let server = PocketServer(id: draft.id, name: draft.name.trimmed.isEmpty ? Self.host(url) ?? url : draft.name.trimmed, url: url,
                                      headers: plans.map(\.name))
            return (draft, server, plans)
        }
        let words = personality.trimmed.isEmpty ? Persona.pocket(named: name.trimmed) : personality.trimmed
        // The secrets first: if the Keychain won't keep them, nothing is saved and you are told.
        let secrets = pocket.secrets
        do {
            if !key.isEmpty { try secrets.set(key, .apiKey, imp: id) }
            else if !keyKept { secrets.remove(.apiKey, imp: id) }
            for (_, server, plans) in made {
                for plan in plans {
                    if !plan.typed.isEmpty {
                        try secrets.set(plan.typed, .header(server.id, plan.name), imp: id)
                    } else if let old = plan.from, old.lowercased() != plan.name.lowercased(),
                              let value = secrets.get(.header(server.id, old), imp: id) {
                        // A saved value under a header that was renamed moves with it.
                        try secrets.set(value, .header(server.id, plan.name), imp: id)
                        secrets.remove(.header(server.id, old), imp: id)
                    }
                }
            }
        } catch {
            saveProblem = String(localized: "Imp couldn't keep the keys safely. \(error.localizedDescription)")
            return
        }
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
                            .buttonStyle(.primary)
                    }
                } else if models == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No models found" : "No match", systemImage: "magnifyingglass")
                } else {
                    List(shown, id: \.self) { id in
                        Button { pick(id); dismiss() } label: {
                            Text(verbatim: id).font(Typeface.mono).foregroundStyle(Dungeon.cream)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .impListRow()
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Dungeon.deep)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .textInputAutocapitalization(.never)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(.automatic) } }
        }
        .impControls(tint: Dungeon.ember)
        .tipHost()
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
