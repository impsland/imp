import AppKit
import ImpKit
import SwiftUI
import UniformTypeIdentifiers

/// Adding a kit, from the first paste to the last tap: the text box, then the review. Nothing is
/// added until Add in the review, whatever the kit came from (pasted, a file, a web address, a link).
@MainActor @Observable
final class KitFlow: Identifiable {
    let id = UUID()
    /// The Imp whose settings it was opened from: who the kit is for to begin with.
    let imp: UUID?
    var text: String { didSet { if !settingText { fileName = nil; limit = Kit.maxBytes } } }
    var error: String?
    var isLoading = false
    var review: KitReview?
    /// Read as soon as the sheet opens (a link): the one thing a link may do is show this review.
    private var pending: KitSource?
    private var origin: String?
    private var fileName: String?
    private var settingText = false
    /// What may be read: files on this Mac can carry chats, so they get more room than a link or pasted text.
    private var limit = Kit.maxBytes

    init(imp: UUID?, text: String = "") {
        self.imp = imp
        self.text = text
    }

    /// From `imp://add?url=`: the address is checked when it's read, and a bad one is shown as such.
    static func link(url: String, imp: UUID?) -> KitFlow {
        let flow = KitFlow(imp: imp, text: url)
        do { flow.pending = try KitSource.web(url) } catch { flow.error = error.localizedDescription }
        return flow
    }

    /// From `imp://add?kit=`: the kit's own JSON.
    static func link(inline json: String, imp: UUID?) -> KitFlow {
        let flow = KitFlow(imp: imp, text: json)
        flow.pending = .text(json)
        flow.origin = String(localized: "A link")
        return flow
    }

    func autoload(_ model: AppModel) async {
        guard let source = pending else { return }
        pending = nil
        await read(source, model: model)
    }

    /// Reads what's in the box (a web address or the kit itself) and moves on to the review.
    func read(model: AppModel) async {
        do { await read(try KitSource(input: text), model: model) } catch { self.error = error.localizedDescription }
    }

    func read(file url: URL, model: AppModel) async {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Kit.maxFileBytes + 1) ?? Data()
            guard data.count <= Kit.maxFileBytes else { throw KitError.tooLarge }
            guard let string = String(data: data, encoding: .utf8) else { throw KitError.download(String(localized: "That isn't a text file.")) }
            settingText = true
            text = data.count <= Kit.maxBytes ? string : url.lastPathComponent      // a big file isn't poured into the box
            settingText = false
            fileName = url.lastPathComponent
            limit = Kit.maxFileBytes
            await read(.text(string), model: model)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func read(_ source: KitSource, model: AppModel) async {
        error = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let json: String, from: String
            switch source {
            case .text(let t): json = t; from = origin ?? fileName.map { String(localized: "File “\($0)”") } ?? String(localized: "Pasted text")
            case .remote(let url): json = try await KitLoader.fetch(url); from = url.host ?? url.absoluteString
            }
            let kit = try Kit.parse(json, limit: limit)
            let imps = model.prefs.imps
            // A kit of Imps is for the whole troupe (its shared triggers stay shared); other kits go to one Imp.
            let target = kit.imps.isEmpty ? imp.flatMap { id in imps.contains { $0.id == id } ? id : nil } ?? imps.first?.id : nil
            review = KitReview(kit: kit, origin: from, existing: model.prefs.shortcuts, services: model.prefs.ai.services, target: target)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A kit up for review: what's in it, what to watch out for, which items are ticked and for whom.
@MainActor @Observable
final class KitReview {
    let kit: Kit
    let origin: String
    let warnings: [KitWarning]
    var triggers: Set<UUID>
    /// The tools no Imp of the kit uses (those an Imp uses come with it).
    var servers: Set<UUID>
    var imps: Set<UUID>
    /// Bring the Imps' chats along (when there are any).
    var includeChats = true
    /// Who gets the triggers and tools that aren't an Imp's own: one Imp, or nil for every Imp.
    var target: UUID?

    init(kit: Kit, origin: String, existing: [Shortcut], services: [Service]? = nil, target: UUID?) {
        self.kit = kit
        self.origin = origin
        self.warnings = kit.warnings(existing: existing, services: services)
        self.triggers = Set(kit.triggers.map(\.id))
        self.servers = Set(kit.looseServers.map(\.id))
        self.imps = Set(kit.imps.map(\.id))
        self.target = target
    }

    /// Imps, triggers and tools that will be added.
    var count: Int { triggers.count + effectiveServers.count + imps.count }
    /// Every tool that will be added: the ticked ones and what the ticked Imps use.
    var effectiveServers: Set<UUID> { servers.union(kit.imps.filter { imps.contains($0.id) }.flatMap(\.servers)) }
    /// Whether anything is for `target` to receive (so there's a choice to make).
    var needsTarget: Bool { !triggers.isEmpty || !servers.isEmpty }
    var hasChats: Bool { kit.imps.contains { !$0.chats.isEmpty } }
    func warnings(for item: UUID) -> [KitWarning] { warnings.filter { $0.item == item } }
    var cautions: [KitWarning] { warnings.filter { $0.isCaution && effectiveServers.contains($0.item) } }

    func binding(trigger id: UUID) -> Binding<Bool> {
        Binding(get: { self.triggers.contains(id) }, set: { if $0 { self.triggers.insert(id) } else { self.triggers.remove(id) } })
    }
    func binding(server id: UUID) -> Binding<Bool> {
        Binding(get: { self.servers.contains(id) }, set: { if $0 { self.servers.insert(id) } else { self.servers.remove(id) } })
    }
    func binding(imp id: UUID) -> Binding<Bool> {
        Binding(get: { self.imps.contains(id) }, set: { if $0 { self.imps.insert(id) } else { self.imps.remove(id) } })
    }
}

/// The kit sheet: the box to paste into, until there's a kit to review.
struct KitFlowSheet: View {
    let model: AppModel
    @Bindable var flow: KitFlow
    @Bindable var router: HomeRouter

    var body: some View {
        Group {
            if let review = flow.review {
                KitReviewSheet(model: model, flow: flow, review: review, router: router)
            } else {
                KitEntrySheet(model: model, flow: flow, router: router)
            }
        }
        .task { await flow.autoload(model) }
    }
}

/// Paste JSON or a web address, or hand over a .json file.
struct KitEntrySheet: View {
    private static let dropHeight: CGFloat = 112
    private static let editorHeight: CGFloat = 96

    let model: AppModel
    @Bindable var flow: KitFlow
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var tint
    @State private var dropping = false

    private var isEmpty: Bool { flow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SheetScaffold(icon: "shippingbox.fill", title: "Add a kit or an Imp",
                      info: "A kit is Imps, triggers and tools somebody shared as JSON. Paste it, give a web address or an imp:// link, or drop a file. You'll see what's in it before anything is added.",
                      width: 520) {
            Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.imp(.secondary, small: true))
                .help("Fill in from the clipboard.")
        } content: {
            if flow.isLoading {
                loading
            } else {
                dropZone
                Text("Or paste a kit or a web address").font(.system(size: 12, weight: .medium)).foregroundStyle(Dungeon.muted)
                    .padding(.bottom, -6)
                EditorWell(text: $flow.text, codePlaceholder: "{ \"imp\": 2, \"imps\": […] }   or   https://example.com/kit.json",
                           mono: true, height: Self.editorHeight)
            }
            if let error = flow.error { ErrorBanner(text: error) }
        } footer: {
            Spacer()
            SheetCancelButton { router.kitFlow = nil }
            Button("Review") { Task { await flow.read(model: model) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(flow.isLoading || isEmpty)
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("Opening the kit…").font(.system(size: 13, weight: .medium)).foregroundStyle(Dungeon.cream)
        }
        .frame(maxWidth: .infinity, minHeight: Self.dropHeight + Self.editorHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .accessibilityElement(children: .combine)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: dropping ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.system(size: 26, weight: .medium)).foregroundStyle(dropping ? tint : Dungeon.muted)
                .symbolEffect(.bounce, value: dropping)
            Text("Drop a .json file here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Dungeon.cream)
            Button("Choose file…") { choose() }.buttonStyle(.imp(.secondary, small: true))
        }
        .frame(maxWidth: .infinity, minHeight: Self.dropHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(dropping ? tint.opacity(0.14) : Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
            .strokeBorder(dropping ? tint : Dungeon.cardEdge, style: StrokeStyle(lineWidth: dropping ? 1.5 : 1, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: \.isFileURL) else { return false }
            Task { await flow.read(file: file, model: model) }
            return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.12), value: dropping)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        flow.text = text
        flow.error = nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a kit (.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await flow.read(file: url, model: model) }
    }
}

/// Something went wrong, said in one orange box.
private struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.system(size: 12.5)).foregroundStyle(Dungeon.cream)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// What's arriving: the Imps' faces in their own colours, the kit's name, what it says about itself, and what's in it.
private struct KitHero: View {
    private static let faceSize: CGFloat = 68
    private static let overlap: CGFloat = 20
    private static let maxFaces = 4
    private static let glowWidth: CGFloat = 340

    let kit: Kit
    let origin: String
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(spacing: 10) {
            faces
            Text(kit.name.isEmpty ? String(localized: "Add a kit") : kit.name)
                .font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream)
                .lineLimit(2).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !kit.about.isEmpty {
                Text(kit.about).font(.system(size: 12.5)).foregroundStyle(Dungeon.muted)
                    .lineLimit(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if !kit.imps.isEmpty { Badge("^[\(kit.imps.count) Imp](inflect: true)", symbol: "person.fill", color: Dungeon.cream) }
                if !kit.triggers.isEmpty { Badge("^[\(kit.triggers.count) trigger](inflect: true)", symbol: "bolt.fill", color: Dungeon.cream) }
                if !kit.servers.isEmpty { Badge("^[\(kit.servers.count) tool](inflect: true)", symbol: "puzzlepiece.extension.fill", color: Dungeon.cream) }
            }
            StatusText(text: "From \(origin)", symbol: "tray.and.arrow.down")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    @ViewBuilder private var faces: some View {
        let shown = Array(kit.imps.prefix(Self.maxFaces))
        let more = kit.imps.count - shown.count
        HStack(spacing: -Self.overlap) {
            if shown.isEmpty {
                Image(systemName: "shippingbox.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: Self.faceSize, height: Self.faceSize)
                    .background(Circle().fill(tint.gradient))
            }
            ForEach(shown) { imp in
                ImpPortrait(face: impFace(hue: imp.hue, mood: .happy), shadow: false)
                    .frame(width: Self.faceSize, height: Self.faceSize)
            }
            if more > 0 {
                Text(verbatim: "+\(more)").font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream)
                    .frame(width: Self.faceSize * 0.6, height: Self.faceSize * 0.6)
                    .background(Circle().fill(Dungeon.card))
                    .padding(.leading, Self.overlap + 4)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            EllipticalGradient(colors: [(shown.first.map { Color.imp($0.hue) } ?? tint).opacity(0.4), .clear],
                               center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: Self.glowWidth)
        }
        .accessibilityHidden(true)
    }
}

/// A group's title above its cards: an icon, a name, a count, and an ⓘ for what to watch out for.
private struct KitSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    @ViewBuilder var content: Content
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Dungeon.cream)
                if let info { InfoTip(info) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// What's in the kit, with a tick on each item, the warnings as badges, who it's for, and Add.
struct KitReviewSheet: View {
    private static let faceSize: CGFloat = 44

    let model: AppModel
    let flow: KitFlow
    @Bindable var review: KitReview
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var inherited

    private var kit: Kit { review.kit }
    /// The first Imp's colour: the sheet takes it on while the Imp arrives.
    private var tint: Color { kit.imps.first.map { Color.imp($0.hue) } ?? inherited }

    var body: some View {
        SheetFrame {
            EmptyView()
        } content: {
            KitHero(kit: kit, origin: review.origin)
            if !review.cautions.isEmpty { caution }
            if !kit.imps.isEmpty { impsSection }
            if !kit.triggers.isEmpty { triggersSection }
            if !kit.looseServers.isEmpty { serversSection }
            if !kit.problems.isEmpty { problemsCard }
        } footer: {
            if review.needsTarget {
                Text("For").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                CompactMenu(verbatim: targetName, symbol: review.target == nil ? "person.3.fill" : "person.fill", maxWidth: 190) {
                    ForEach(model.prefs.imps) { imp in
                        Button { review.target = imp.id } label: {
                            if review.target == imp.id { Label(name(of: imp), systemImage: "checkmark") } else { Text(name(of: imp)) }
                        }
                    }
                    Divider()
                    Button { review.target = nil } label: {
                        if review.target == nil { Label("Every Imp", systemImage: "checkmark") } else { Text("Every Imp") }
                    }
                }
                .help("Who gets the triggers and tools that aren't an Imp's own.")
            }
            Spacer()
            SheetCancelButton { router.kitFlow = nil }
            Button { add() } label: { Label(addTitle, systemImage: "plus") }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(review.count == 0)
                .help("Nothing is added until you press this.")
        }
        .environment(\.impTint, tint)
    }

    private var addTitle: LocalizedStringKey {
        let onlyImps = review.triggers.isEmpty && review.servers.isEmpty
        return onlyImps && !review.imps.isEmpty ? "Add ^[\(review.imps.count) Imp](inflect: true)" : "Add ^[\(review.count) item](inflect: true)"
    }

    private func name(of imp: ImpProfile) -> String { imp.name.isEmpty ? String(localized: "Unnamed Imp") : imp.name }
    private var targetName: String { review.target.flatMap(model.profile).map(name(of:)) ?? String(localized: "Every Imp") }

    /// Code that would run on this Mac, said plainly.
    private var caution: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Runs commands on this Mac").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Dungeon.cream)
                InfoTip("Only add it if you trust whoever sent it.")
            }
            ForEach(review.cautions) { warning in
                Text(warning.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Dungeon.cream.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }

    /// A warning as a badge: what it is in a few words, the details in its tooltip.
    @ViewBuilder private func badge(_ warning: KitWarning) -> some View {
        switch warning.kind {
        case .runsCommand: Badge("Runs commands", symbol: "terminal.fill", color: .orange).help(warning.text)
        case .computerControl: Badge("Controls your Mac", symbol: "cursorarrow.click.2", color: .orange).help(warning.text)
        case .needsSecrets: Badge("Needs keys", symbol: "key.fill", color: Dungeon.ember).help(warning.text)
        case .keysInUse: Badge("Keys in use", symbol: "keyboard", color: .orange).help(warning.text)
        case .brainMissing: Badge("Model not set up", symbol: "brain", color: .orange).help(warning.text)
        }
    }

    // MARK: Imps

    private var impsSection: some View {
        KitSection(icon: "person.fill", title: "Imps",
                   info: "An Imp arrives at home, not out on your desktop. Its personality and triggers steer what it does with its tools, commands on your Mac included. Read them.") {
            ForEach(kit.imps) { imp in
                SelectableCard(isOn: review.binding(imp: imp.id), tint: Color.imp(imp.hue)) { impCard(imp) }
            }
            if review.hasChats {
                Toggle("Bring their chats along", isOn: $review.includeChats).toggleStyle(.checkbox)
                    .font(.system(size: 12.5)).foregroundStyle(Dungeon.cream)
                    .padding(.leading, 4)
            }
        }
    }

    private func impCard(_ imp: KitImp) -> some View {
        let warnings = review.warnings(for: imp.id) + imp.triggers.flatMap { review.warnings(for: $0.id) }
        let tools = imp.toolsOn.map(\.title) + (imp.usesShell ? [String(localized: "Commands")] : [])
        let servers = imp.servers.compactMap { id in kit.servers.first { $0.id == id }?.name }
        let model = imp.brain.map(\.summary).flatMap { $0.isEmpty ? nil : $0 }
        return HStack(alignment: .top, spacing: 12) {
            ImpPortrait(face: impFace(hue: imp.hue), shadow: false)
                .frame(width: Self.faceSize, height: Self.faceSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(imp.name).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                if !imp.personality.isEmpty {
                    Text(imp.personality).font(.system(size: 12)).foregroundStyle(Dungeon.cream.opacity(0.85))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(warnings) { badge($0) }
                    Badge(verbatim: model ?? String(localized: "Your default model"), symbol: "brain")
                        .help("The model it thinks with.")
                    if tools.isEmpty {
                        Badge("No tools", symbol: "wrench.and.screwdriver.fill")
                    } else {
                        Badge("^[\(tools.count) tool](inflect: true)", symbol: "wrench.and.screwdriver.fill").help(tools.joined(separator: ", "))
                    }
                    if !servers.isEmpty {
                        Badge(verbatim: servers.joined(separator: ", "), symbol: "puzzlepiece.extension.fill").help("The tools it uses.")
                    }
                    if !imp.triggers.isEmpty { Badge("^[\(imp.triggers.count) trigger](inflect: true)", symbol: "bolt.fill") }
                    if !imp.chats.isEmpty { Badge("^[\(imp.chats.count) chat](inflect: true)", symbol: "bubble.left.and.bubble.right.fill") }
                }
            }
        }
    }

    // MARK: Triggers and tools

    private var triggersSection: some View {
        KitSection(icon: "bolt.fill", title: "Triggers",
                   info: "A trigger gives the Imp an instruction it carries out with its tools, commands on your Mac included. Read what it says.") {
            ForEach(kit.triggers) { trigger in
                SelectableCard(isOn: review.binding(trigger: trigger.id)) { triggerCard(trigger) }
            }
        }
    }

    private func triggerCard(_ trigger: Shortcut) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(trigger.displayName).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
            Label(trigger.triggerSummary, systemImage: trigger.trigger.kind.symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Dungeon.cream.opacity(0.85)).lineLimit(2)
            if trigger.command != .ask {
                Text(trigger.command.title).font(.system(size: 12)).foregroundStyle(Dungeon.muted)
            } else if !trigger.prompt.isEmpty {
                Text(trigger.prompt).font(.system(size: 12)).foregroundStyle(Dungeon.muted)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            let warnings = review.warnings(for: trigger.id)
            if (trigger.command == .ask && trigger.usesClipboard) || !warnings.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(warnings) { badge($0) }
                    if trigger.command == .ask && trigger.usesClipboard {
                        Badge("Sends your clipboard", symbol: "doc.on.clipboard").help("It sends what you copied along with the instruction.")
                    }
                }
            }
        }
    }

    private var serversSection: some View {
        KitSection(icon: "puzzlepiece.extension.fill", title: "Tools") {
            ForEach(kit.looseServers) { server in
                SelectableCard(isOn: review.binding(server: server.id)) { serverCard(server) }
            }
        }
    }

    private func serverCard(_ server: MCPServerConfig) -> some View {
        let local = server.transport == .stdio
        let warnings = review.warnings(for: server.id)
        return VStack(alignment: .leading, spacing: 5) {
            Label { Text(server.name).lineLimit(1) } icon: { Image(systemName: local ? "terminal.fill" : "globe") }
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text(local ? server.commandLine : server.url)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Dungeon.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !warnings.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) { ForEach(warnings) { badge($0) } }
            }
        }
    }

    private var problemsCard: some View {
        Card("Skipped", icon: "exclamationmark.circle") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(kit.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Adding

    private func add() {
        var prefs = model.prefs
        let added = prefs.add(kit, imps: review.imps, triggers: review.triggers, servers: review.servers, for: review.target,
                              withChats: review.includeChats)
        // Chats go to the Imp's folder before it appears, so it opens them as its own.
        if model.persists {
            for imported in added.imps where !imported.chats.isEmpty {
                var history = ChatHistory(folder: ChatHistory.folder(for: imported.id))
                for chat in imported.chats { history.adopt(chat) }
            }
        }
        withAnimation(.snappy(duration: 0.2)) { model.prefs = prefs }
        router.kitFlow = nil
        // New Imps hatch on the stage first. Then, if a tool needs keys, its form opens.
        let needing = added.needingSecrets.first
        let target = review.target ?? flow.imp ?? added.imps.first?.id
        router.hatch(added.imps.map(\.id)) { [model, router] in
            guard let needing else { return }
            let imp = target ?? router.selection ?? model.prefs.imps[0].id
            HomeWindow.shared.show(model, settingsFor: imp, tab: .tools)
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                router.serverToEdit = needing
            }
        }
    }
}

// MARK: - Sharing

/// The version of the app that writes a kit (informational: the format version is the kit's own).
enum AppInfo {
    static var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
}

extension Kit {
    /// With the app's version noted in it, as written to the clipboard or a file.
    var stamped: Kit {
        var kit = self
        if kit.app == nil { kit.app = AppInfo.version }
        return kit
    }
}

/// Copies a kit to the clipboard, as JSON or as an imp:// link when it's short enough for one.
@MainActor
enum KitSharing {
    static func copy(_ kit: Kit) { Pasteboard.write(text: kit.stamped.json()) }
    static func copyLink(_ kit: Kit) { if let link = kit.stamped.link { Pasteboard.write(text: link) } }
}

/// A small share button: Copy the kit, or Copy a link to it. A tick says it worked.
struct ShareKitButton: View {
    let kit: Kit
    let help: LocalizedStringResource
    @State private var copied = false

    var body: some View {
        let linkable = kit.stamped.link != nil
        Menu {
            Button("Copy kit") { done(KitSharing.copy(kit)) }
            Button("Copy link") { done(KitSharing.copyLink(kit)) }
                .disabled(!linkable)
        } label: {
            HoverGlyph(systemName: copied ? "checkmark" : "square.and.arrow.up", tint: copied ? .green : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(linkable ? String(localized: help) : String(localized: "\(String(localized: help)) It's too long for a link."))
        .accessibilityLabel(Text(help))
    }

    private func done(_ action: @autoclosure () -> Void) {
        action()
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}

// MARK: - Exporting Imps

/// Imps as kits: shared from the clipboard, or saved as a file (a backup, a move to another Mac).
@MainActor
enum ImpExport {
    /// The Imps `ids` with their triggers and tools (and `shared` triggers). Chats are read from
    /// each Imp's history when `chats` is set.
    static func kit(_ ids: Set<UUID>, model: AppModel, name: String, shared: Bool = false, chats: Bool = false) -> Kit {
        var history: [UUID: [Chat]] = [:]
        if chats { for id in ids { history[id] = model.imp(id)?.history.savedChats() ?? [] } }
        return Kit.exporting(imps: ids, from: model.prefs, name: name, shared: shared, chats: history).stamped
    }

    static func hasChats(_ ids: Set<UUID>, model: AppModel) -> Bool {
        ids.contains { id in model.imp(id)?.history.chats.contains { $0.peer == nil } == true }
    }

    /// Asks where to save, with an "Include chats" tick when there are chats to include.
    static func save(_ ids: Set<UUID>, model: AppModel, name: String, fileName: String, shared: Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName + ".json"
        panel.message = String(localized: "Save \(name) as a kit file. Imp reads it back with Import, on this Mac or another. API keys are never saved.")
        panel.canCreateDirectories = true
        let box = NSButton(checkboxWithTitle: String(localized: "Include chats"), target: nil, action: nil)
        if hasChats(ids, model: model) {
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
            box.frame = NSRect(x: 20, y: 6, width: 260, height: 24)
            holder.addSubview(box)
            panel.accessoryView = holder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let kit = kit(ids, model: model, name: name, shared: shared, chats: box.state == .on && panel.accessoryView != nil)
        let text = kit.json()
        do {
            guard text.utf8.count <= Kit.maxFileBytes else {
                throw KitError.download(String(localized: "That's too big to read back (the limit is \(Kit.maxFileBytes / 1_048_576) MB). Export without chats, or a few Imps at a time."))
            }
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn't save the file")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
