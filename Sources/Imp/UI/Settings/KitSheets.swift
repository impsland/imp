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
    var text: String { didSet { if !settingText { fileName = nil } } }
    var error: String?
    var isLoading = false
    var review: KitReview?
    /// Read as soon as the sheet opens (a link): the one thing a link may do is show this review.
    private var pending: KitSource?
    private var origin: String?
    private var fileName: String?
    private var settingText = false

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
        flow.origin = "A link"
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
            let data = try handle.read(upToCount: Kit.maxBytes + 1) ?? Data()
            guard data.count <= Kit.maxBytes else { throw KitError.tooLarge }
            guard let string = String(data: data, encoding: .utf8) else { throw KitError.download("That isn't a text file.") }
            settingText = true
            text = string
            settingText = false
            fileName = url.lastPathComponent
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
            case .text(let t): json = t; from = origin ?? fileName.map { "File “\($0)”" } ?? "Pasted text"
            case .remote(let url): json = try await KitLoader.fetch(url); from = url.host ?? url.absoluteString
            }
            let kit = try Kit.parse(json)
            let imps = model.prefs.imps
            let target = imp.flatMap { id in imps.contains { $0.id == id } ? id : nil } ?? imps.first?.id
            review = KitReview(kit: kit, origin: from, existing: model.prefs.shortcuts, target: target)
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
    var servers: Set<UUID>
    /// Who gets them: one Imp, or nil for every Imp.
    var target: UUID?

    init(kit: Kit, origin: String, existing: [Shortcut], target: UUID?) {
        self.kit = kit
        self.origin = origin
        self.warnings = kit.warnings(existing: existing)
        self.triggers = Set(kit.triggers.map(\.id))
        self.servers = Set(kit.servers.map(\.id))
        self.target = target
    }

    var count: Int { triggers.count + servers.count }
    func warnings(for item: UUID) -> [KitWarning] { warnings.filter { $0.item == item } }
    var cautions: [KitWarning] { warnings.filter { $0.isCaution && servers.contains($0.item) } }

    func binding(trigger id: UUID) -> Binding<Bool> {
        Binding(get: { self.triggers.contains(id) }, set: { if $0 { self.triggers.insert(id) } else { self.triggers.remove(id) } })
    }
    func binding(server id: UUID) -> Binding<Bool> {
        Binding(get: { self.servers.contains(id) }, set: { if $0 { self.servers.insert(id) } else { self.servers.remove(id) } })
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
    let model: AppModel
    @Bindable var flow: KitFlow
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var tint
    @State private var dropping = false

    var body: some View {
        SheetScaffold(icon: "shippingbox.fill", title: "Add a kit", width: 540) {
            Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.imp(.secondary, small: true))
                .help("Paste what's on the clipboard")
        } content: {
            Text("A kit is triggers and tools somebody shared as JSON. Paste it, give a web address or an imp:// link, or drop a file. You'll see what's in it before anything is added.")
                .font(.system(size: 12)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
            EditorWell(text: $flow.text, placeholder: "{ \"imp\": 1, \"triggers\": […] }   or   https://example.com/kit.json",
                       mono: true, height: 140)
            dropZone
            if let error = flow.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12)).foregroundStyle(Dungeon.cream)
            }
        } footer: {
            if flow.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { router.kitFlow = nil }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Review") { Task { await flow.read(model: model) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(flow.isLoading || flow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.plus").font(.system(size: 15)).foregroundStyle(dropping ? tint : Dungeon.muted)
            Text("Drop a .json file here").font(.system(size: 12.5)).foregroundStyle(Dungeon.cream.opacity(0.85))
            Spacer(minLength: 8)
            Button("Choose file…") { choose() }.buttonStyle(.imp(.quiet, small: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(dropping ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(dropping ? tint : Dungeon.cardEdge, style: StrokeStyle(lineWidth: dropping ? 1.5 : 1, dash: [5, 4])))
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
        panel.message = "Choose a kit (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await flow.read(file: url, model: model) }
    }
}

/// What's in the kit, with a tick on each item, the warnings up top, who it's for, and Add.
struct KitReviewSheet: View {
    let model: AppModel
    let flow: KitFlow
    @Bindable var review: KitReview
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var tint

    private var kit: Kit { review.kit }

    var body: some View {
        SheetScaffold(icon: "shippingbox.fill", title: kit.name.isEmpty ? "Add a kit" : kit.name,
                      info: "Nothing is added until you press Add. Untick what you don't want.", width: 540) {
            about
            if !review.cautions.isEmpty { caution }
            if !kit.triggers.isEmpty { triggersCard }
            if !kit.servers.isEmpty { serversCard }
            if !kit.problems.isEmpty { problemsCard }
        } footer: {
            Text("For").font(.system(size: 12)).foregroundStyle(Dungeon.muted)
            CompactMenu(title: targetName, symbol: review.target == nil ? "person.3.fill" : "person.fill", maxWidth: 190) {
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
            Spacer()
            Button("Cancel", role: .cancel) { router.kitFlow = nil }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button(review.count == 1 ? "Add 1 item" : "Add \(review.count) items") { add() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(review.count == 0)
        }
    }

    private func name(of imp: ImpProfile) -> String { imp.name.isEmpty ? "Unnamed Imp" : imp.name }
    private var targetName: String { review.target.flatMap(model.profile).map(name(of:)) ?? "Every Imp" }

    private var about: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !kit.about.isEmpty {
                Text(kit.about).font(.system(size: 13)).foregroundStyle(Dungeon.cream).fixedSize(horizontal: false, vertical: true)
            }
            StatusText(text: "From \(review.origin)", symbol: "tray.and.arrow.down")
        }
    }

    /// Code that would run on this Mac, said plainly.
    private var caution: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Runs code on this Mac").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Dungeon.cream)
            }
            ForEach(review.cautions) { warning in
                Text(warning.text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Dungeon.cream.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Only add it if you trust whoever sent it.").font(.system(size: 11.5)).foregroundStyle(Dungeon.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }

    private var triggersCard: some View {
        Card(kit.triggers.count == 1 ? "Trigger" : "Triggers", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(kit.triggers) { trigger in
                    triggerRow(trigger)
                    if trigger.id != kit.triggers.last?.id { CardDivider() }
                }
                Text("A trigger gives the Imp an instruction it carries out with its tools, commands on your Mac included. Read what it says.")
                    .font(.system(size: 11)).foregroundStyle(Dungeon.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggerRow(_ trigger: Shortcut) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: review.binding(trigger: trigger.id)).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                Text(trigger.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Label(trigger.triggerSummary, systemImage: trigger.trigger.kind.symbol)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Dungeon.cream.opacity(0.85)).lineLimit(2)
                if trigger.command != .ask {
                    Text(trigger.command.title).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted)
                } else if !trigger.prompt.isEmpty {
                    Text(trigger.prompt).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if trigger.command == .ask && trigger.usesClipboard {
                    Text("Sends what you copied").font(.system(size: 11)).foregroundStyle(Dungeon.muted)
                }
                ForEach(review.warnings(for: trigger.id)) { warning in
                    Label(warning.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var serversCard: some View {
        Card(kit.servers.count == 1 ? "Tool" : "Tools", icon: "puzzlepiece.extension.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(kit.servers) { server in
                    serverRow(server)
                    if server.id != kit.servers.last?.id { CardDivider() }
                }
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: review.binding(server: server.id)).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: server.transport == .stdio ? "terminal.fill" : "globe")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(server.transport == .stdio ? .orange : tint)
                    Text(server.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                Text(server.transport == .stdio ? server.commandLine : server.url)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Dungeon.muted)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                ForEach(review.warnings(for: server.id).filter { !$0.isCaution }) { warning in
                    Label(warning.text + ". Its form opens after adding.", systemImage: "key.fill")
                        .font(.system(size: 11)).foregroundStyle(Dungeon.ember).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
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
        let added = prefs.add(kit, triggers: review.triggers, servers: review.servers, for: review.target)
        withAnimation(.snappy(duration: 0.2)) { model.prefs = prefs }
        router.kitFlow = nil
        // Keys to fill in: open that tool's form once this sheet has gone.
        guard let needing = added.needingSecrets.first else { return }
        let imp = review.target ?? flow.imp ?? router.selection ?? model.prefs.imps[0].id
        HomeWindow.shared.show(model, settingsFor: imp, tab: .tools)
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            router.serverToEdit = needing
        }
    }
}

// MARK: - Sharing

/// Copies a kit to the clipboard, as JSON or as an imp:// link when it's short enough for one.
@MainActor
enum KitSharing {
    static func copy(_ kit: Kit) { Pasteboard.write(text: kit.json()) }
    static func copyLink(_ kit: Kit) { if let link = kit.link { Pasteboard.write(text: link) } }
}

/// A small share button: Copy the kit, or Copy a link to it. A tick says it worked.
struct ShareKitButton: View {
    let kit: Kit
    let help: String
    @State private var copied = false

    var body: some View {
        Menu {
            Button("Copy kit") { done(KitSharing.copy(kit)) }
            Button("Copy link") { done(KitSharing.copyLink(kit)) }
                .disabled(kit.link == nil)
        } label: {
            HoverGlyph(systemName: copied ? "checkmark" : "square.and.arrow.up", tint: copied ? .green : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(kit.link == nil ? help + " (too long for a link)" : help)
        .accessibilityLabel(help)
    }

    private func done(_ action: @autoclosure () -> Void) {
        action()
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
    }
}
