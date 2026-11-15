import ImpDesign
import ImpKit
import SwiftUI

/// One header of a tool server being edited.
struct HeaderDraft: Identifiable {
    var id = UUID()
    var name = ""
    /// A new value. Empty keeps the saved one.
    var value = ""
    /// The name the saved value was kept under, if there is one.
    var savedName: String?

    var isBlank: Bool { name.trimmed.isEmpty && value.isEmpty }
}

/// One tool server being edited.
struct ServerDraft: Identifiable {
    var id = UUID()
    var name = ""
    var url = ""
    var headers: [HeaderDraft] = []
    /// The host the saved values were meant for.
    var savedFor: String?

    var isBlank: Bool { name.trimmed.isEmpty && url.trimmed.isEmpty && headers.allSatisfy(\.isBlank) }
    var holdsSecrets: Bool { headers.contains { $0.savedName != nil || !$0.value.isEmpty } }
    var hostKept: Bool { savedFor != nil && savedFor == PocketDraft.host(url) }
}

/// Everything the editor changes about one Imp. The editor saves it as it changes (`PocketEditor`), so there is
/// no Save button and closing never loses anything. The Brain is owned by the Brain form (`FirstRunModel`): it
/// hands a checked Brain to `adopt`, and the draft only reads it.
@MainActor @Observable
final class PocketDraft {
    struct KeyProblem: LocalizedError {
        let detail: String
        var errorDescription: String? { String(format: String(localized: "phone.editor.save_failed"), detail) }
    }

    static var hues: [Double] { PocketRuntime.hues }
    /// The settings this iPhone has. Triggers and Moves live on the Mac.
    static let settings: [ImpSetting] = [.brain, .personality, .look, .tools]
    /// The Imp's own tools this iPhone has, each with a switch: messaging the other Imps, and playing its animations.
    static let ownTools: [ToolEntry] = [OwnTools.message, OwnTools.play].compactMap(ToolRegistry.entry(named:))

    let id: UUID
    var name: String
    var hue: Double
    var scale: Double
    var traits: ImpTraits
    var personality: String
    var servers: [ServerDraft]
    /// The Imp's own tools switched off, by registry id.
    var toolsOff: Set<String>
    /// The Brain as it will be saved.
    private(set) var brain: PocketService
    /// A key the flow checked, to store on Save. Empty means no key. Nil keeps what is saved.
    private(set) var newKey: String?

    init(pocket: PocketRuntime, editing: UUID) {
        let imp = pocket.imps.first { $0.id == editing }
        let secrets = pocket.secrets
        id = editing
        name = imp?.name ?? ""
        hue = imp?.hue ?? ImpProfile.defaultHue
        scale = imp?.scale ?? PocketRuntime.newSize
        traits = imp?.traits ?? .plain
        personality = imp.map { $0.personality == Persona.pocket(named: $0.name) ? "" : $0.personality } ?? ""
        brain = imp?.brain ?? PocketService()
        toolsOff = Set(imp?.toolsOff ?? [])
        servers = imp?.servers.map { server -> ServerDraft in
            let heads = server.headers.map { name in
                HeaderDraft(name: name, savedName: imp.flatMap { secrets.get(.header(server.id, name), imp: $0.id) != nil ? name : nil })
            }
            return ServerDraft(id: server.id, name: server.name, url: server.url, headers: heads,
                               savedFor: heads.contains { $0.savedName != nil } ? Self.host(server.url) : nil)
        } ?? []
    }

    // MARK: Tools

    func uses(_ tool: ToolEntry) -> Bool { !toolsOff.contains(tool.id) }

    func setUses(_ tool: ToolEntry, _ on: Bool) {
        if on { toolsOff.remove(tool.id) } else { toolsOff.insert(tool.id) }
    }

    /// The tools it has on, of all it has: its own and the servers that are ready.
    var toolCount: (on: Int, all: Int) {
        let real = servers.filter { !$0.isBlank }
        return (Self.ownTools.filter(uses).count + real.filter { serverProblem($0) == nil }.count, Self.ownTools.count + real.count)
    }

    // MARK: The Brain

    var hasBrain: Bool { !brain.baseURL.trimmed.isEmpty && !brain.model.trimmed.isEmpty }
    var service: ServicePreset? { ServicePreset.matching(brain.baseURL) }
    /// The service's name for a value on screen.
    var serviceName: String { brain.name ?? service?.title ?? Self.host(brain.baseURL) ?? "" }

    /// Takes the Brain the flow checked. `stored`: its key is in the Keychain already.
    func adopt(_ checked: FirstRunBrain, stored: Bool = false) {
        brain = PocketService(checked)
        newKey = stored ? nil : checked.key
    }

    // MARK: Checking

    var nameProblem: String? {
        name.trimmed.count > PocketImp.maxName ? PocketError.badName.errorDescription : nil
    }

    /// A card you haven't filled in yet is fine (it's left out). One with something in it needs its address.
    func serverProblem(_ server: ServerDraft) -> String? {
        if server.isBlank { return nil }
        if server.url.trimmed.isEmpty { return String(localized: "tools.problem.address") }
        do { try PocketImp.check(url: server.url); return nil } catch { return error.localizedDescription }
    }

    var canSave: Bool {
        guard !name.trimmed.isEmpty, nameProblem == nil else { return false }
        return servers.allSatisfy { $0.isBlank || serverProblem($0) == nil }
    }

    var isPlainCharacter: Bool { traits.isPlain }

    func resetCharacter() { traits = .plain }

    /// Where an address leads. A secret saved for one place isn't sent to another.
    nonisolated static func host(_ address: String) -> String? {
        URL(string: address.trimmed)?.host()?.lowercased()
    }

    // MARK: Saving

    /// Stores the keys, then the Imp. Throws `KeyProblem` and changes nothing when the Keychain refuses a secret.
    func save(into pocket: PocketRuntime) throws {
        guard canSave else { return }
        /// A header to keep: its name and the value to store now, or the saved one under `from`.
        struct Plan { var name: String; var typed: String; var from: String? }
        let made: [(PocketServer, [Plan])] = servers.filter { !$0.isBlank }.map { draft in
            let url = draft.url.trimmed
            var seen: Set<String> = []
            var plans: [Plan] = []
            for header in draft.headers {
                let kept = draft.hostKept && header.savedName != nil
                guard !header.value.isEmpty || kept else { continue }
                let name = header.name.trimmed.isEmpty ? "Authorization" : header.name.trimmed
                guard plans.count < PocketServer.maxHeaders, seen.insert(name.lowercased()).inserted else { continue }
                plans.append(Plan(name: name, typed: header.value, from: kept ? header.savedName : nil))
            }
            let server = PocketServer(id: draft.id, name: draft.name.trimmed.isEmpty ? Self.host(url) ?? url : draft.name.trimmed, url: url,
                                      headers: plans.map(\.name))
            return (server, plans)
        }
        let words = personality.trimmed.isEmpty ? Persona.pocket(named: name.trimmed) : personality.trimmed
        let secrets = pocket.secrets
        do {
            if let newKey {
                if newKey.isEmpty { secrets.remove(.apiKey, imp: id) } else { try secrets.set(newKey, .apiKey, imp: id) }
            }
            for (server, plans) in made {
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
            throw KeyProblem(detail: error.localizedDescription)
        }
        newKey = nil
        let service = brain
        let off = toolsOff.sorted()
        pocket.edit(id) { imp in
            imp.name = name.trimmed
            imp.hue = hue
            imp.scale = scale
            imp.traits = traits
            imp.personality = words
            imp.brain = service
            imp.servers = made.map(\.0)
            imp.toolsOff = off.isEmpty ? nil : off
        }
    }

    /// What saving depends on, to save again when it changes. Header values count, so a typed one is kept.
    /// The name is first and the personality fifth (the editor waits longer after typing).
    var fingerprint: [String] {
        [name, "\(hue)", "\(scale)", String(describing: traits), personality, toolsOff.sorted().joined(separator: ","), brain.baseURL, brain.model]
            + servers.flatMap { [$0.name, $0.url] + $0.headers.flatMap { [$0.name, $0.value] } }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
