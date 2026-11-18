import AppKit
import ImpDesign
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

    /// Opened from the triggers every Imp shares: what it adds is for every Imp to begin with.
    let forEveryImp: Bool
    /// A pocket Imp from another device asking to move in for good: Add answers yes, and leaving the
    /// review any other way answers no.
    var adoption: ((Bool) -> Void)?

    /// The review is gone without Add: a pocket Imp waiting to move in is turned down.
    func abandon() {
        let decide = adoption
        adoption = nil
        decide?(false)
    }

    init(imp: UUID?, text: String = "", forEveryImp: Bool = false) {
        self.imp = imp
        self.text = text
        self.forEveryImp = forEveryImp
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

    /// From the model's `imp_add_kit`: a kit document (or a single trigger or MCP snippet) it passes
    /// along. Only the review opens: nothing is added until the person confirms there.
    static func offered(json: String, imp: UUID?, origin: String) -> KitFlow {
        let flow = KitFlow(imp: imp, text: json)
        flow.pending = .text(json)
        flow.origin = origin
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
            try present(json: json, from: from, model: model)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func present(json: String, from: String, model: AppModel) throws {
        let kit = try Kit.parse(json, limit: limit)
        let imps = model.prefs.imps
        // A kit of Imps is for the whole troupe (its shared triggers stay shared). Other kits go to one Imp.
        let target = kit.imps.isEmpty && !forEveryImp ? imp.flatMap { id in imps.contains { $0.id == id } ? id : nil } ?? imps.first?.id : nil
        review = KitReview(kit: kit, origin: from, existing: model.prefs.shortcuts, services: model.prefs.ai.services, target: target)
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
    var animations: Set<UUID>
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
        self.animations = Set(kit.animations.map(\.id))
        self.target = target
    }

    /// Imps, triggers and tools that will be added.
    var count: Int { triggers.count + effectiveServers.count + imps.count + animations.count }
    /// Every tool that will be added: the ticked ones and what the ticked Imps use.
    var effectiveServers: Set<UUID> { servers.union(kit.imps.filter { imps.contains($0.id) }.flatMap(\.servers)) }
    /// Whether anything is for `target` to receive (so there's a choice to make).
    var needsTarget: Bool { !triggers.isEmpty || !servers.isEmpty || !animations.isEmpty }
    var hasChats: Bool { kit.imps.contains { !$0.chats.isEmpty } }
    func warnings(for item: UUID) -> [KitWarning] { warnings.filter { $0.item == item } }
    var cautions: [KitWarning] { warnings.filter { $0.isCaution && effectiveServers.contains($0.item) } }

    func binding(trigger id: UUID) -> Binding<Bool> {
        Binding(get: { self.triggers.contains(id) }, set: { if $0 { self.triggers.insert(id) } else { self.triggers.remove(id) } })
    }
    func binding(server id: UUID) -> Binding<Bool> {
        Binding(get: { self.servers.contains(id) }, set: { if $0 { self.servers.insert(id) } else { self.servers.remove(id) } })
    }
    func binding(animation id: UUID) -> Binding<Bool> {
        Binding(get: { self.animations.contains(id) }, set: { if $0 { self.animations.insert(id) } else { self.animations.remove(id) } })
    }
    func binding(imp id: UUID) -> Binding<Bool> {
        Binding(get: { self.imps.contains(id) }, set: { if $0 { self.imps.insert(id) } else { self.imps.remove(id) } })
    }
}
