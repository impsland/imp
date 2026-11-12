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

/// Everything the editor changes about one Imp, held until Save. The Brain is owned by the first-run flow
/// (`FirstRunModel`): it hands a checked Brain to `adopt`, and the draft only reads it.
@MainActor @Observable
final class PocketDraft {
    struct KeyProblem: LocalizedError {
        let detail: String
        var errorDescription: String? { String(format: String(localized: "phone.editor.save_failed"), detail) }
    }

    static let hues: [Double] = [0, 0.08, 0.15, 0.33, 0.5, 0.6, 0.75, 0.9]
    /// The size a new Imp starts with.
    static let newSize = 1.7
    /// The settings this iPhone has. Triggers and Moves live on the Mac.
    static let settings: [ImpSetting] = [.brain, .personality, .look, .tools]

    let id: UUID
    let isNew: Bool
    var name: String
    var hue: Double
    var scale: Double
    var traits: ImpTraits
    var personality: String
    var servers: [ServerDraft]
    /// The Brain as it will be saved.
    private(set) var brain: PocketService
    /// A key the flow checked, to store on Save. Empty means no key. Nil keeps what is saved.
    private(set) var newKey: String?

    init(pocket: PocketRuntime, editing: UUID?) {
        let imp = editing.flatMap { id in pocket.imps.first { $0.id == id } }
        let secrets = pocket.secrets
        id = imp?.id ?? UUID()
        isNew = imp == nil
        name = imp?.name ?? ImpProfile.randomName(avoiding: pocket.imps.map(\.name))
        hue = imp?.hue ?? Self.hues.randomElement() ?? 0
        scale = imp?.scale ?? Self.newSize
        traits = imp?.traits ?? .plain
        personality = imp.map { $0.personality == Persona.pocket(named: $0.name) ? "" : $0.personality } ?? ""
        brain = imp?.brain ?? PocketService()
        servers = imp?.servers.map { server -> ServerDraft in
            let heads = server.headers.map { name in
                HeaderDraft(name: name, savedName: imp.flatMap { secrets.get(.header(server.id, name), imp: $0.id) != nil ? name : nil })
            }
            return ServerDraft(id: server.id, name: server.name, url: server.url, headers: heads,
                               savedFor: heads.contains { $0.savedName != nil } ? Self.host(server.url) : nil)
        } ?? []
    }

    // MARK: The Brain

    var hasBrain: Bool { !brain.baseURL.trimmed.isEmpty && !brain.model.trimmed.isEmpty }
    var service: ServicePreset? { ServicePreset.matching(brain.baseURL) }
    /// The service's name for a value on screen.
    var serviceName: String { brain.name ?? service?.title ?? Self.host(brain.baseURL) ?? "" }

    /// Takes the Brain the flow checked.
    func adopt(_ checked: FirstRunBrain) {
        brain = PocketService(checked)
        newKey = checked.key
    }

    // MARK: Checking

    var nameProblem: String? {
        name.trimmed.count > PocketImp.maxName ? PocketError.badName.errorDescription : nil
    }

    /// A card you haven't filled in yet is fine (it's left out); one with something in it needs its address.
    func serverProblem(_ server: ServerDraft) -> String? {
        if server.isBlank { return nil }
        if server.url.trimmed.isEmpty { return String(localized: "tools.problem.address") }
        do { try PocketImp.check(url: server.url); return nil } catch { return error.localizedDescription }
    }

    var canSave: Bool {
        guard !name.trimmed.isEmpty, nameProblem == nil else { return false }
        return servers.allSatisfy { $0.isBlank || serverProblem($0) == nil }
    }

    var isPlainLook: Bool { abs(hue - ImpProfile.defaultHue) < 0.005 && scale == 1 && traits.isPlain }

    func resetLook() { hue = ImpProfile.defaultHue; scale = 1; traits = .plain }

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
        let service = brain
        if isNew {
            pocket.hatch(PocketImp(id: id, name: name.trimmed, hue: hue, scale: scale, traits: traits, personality: words, brain: service,
                                   servers: made.map(\.0)))
        } else {
            pocket.edit(id) { imp in
                imp.name = name.trimmed
                imp.hue = hue
                imp.scale = scale
                imp.traits = traits
                imp.personality = words
                imp.brain = service
                imp.servers = made.map(\.0)
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
