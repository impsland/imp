import Foundation
import ImpKit
import Observation

/// The Imps hatched on this iPhone. Their chats and settings are one JSON file in Application
/// Support, readable once the phone has been unlocked. Their keys are in the Keychain, never here.
@MainActor @Observable
final class PocketStore {
    private(set) var imps: [PocketImp]
    @ObservationIgnored let secrets: any PocketSecrets
    @ObservationIgnored private let url: URL

    init(secrets: any PocketSecrets = PocketKeychain(), url: URL = URL.applicationSupportDirectory.appending(path: "pocket-imps.json")) {
        self.secrets = secrets
        self.url = url
        imps = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PocketImp].self, from: $0) } ?? []
    }

    func imp(_ id: UUID) -> PocketImp? { imps.first { $0.id == id } }

    func contains(_ id: UUID) -> Bool { imps.contains { $0.id == id } }

    func add(_ imp: PocketImp) {
        guard !contains(imp.id) else { return }
        imps.append(imp)
        persist()
    }

    /// Changes an Imp. The header values of servers it no longer has are forgotten.
    func update(_ id: UUID, _ change: (inout PocketImp) -> Void) {
        guard let i = imps.firstIndex(where: { $0.id == id }) else { return }
        let before = imps[i].servers
        change(&imps[i])
        let kept = Set(imps[i].servers.filter { $0.header != nil }.map(\.id))
        for server in before where !kept.contains(server.id) { secrets.remove(.header(server.id), imp: id) }
        persist()
    }

    /// Forgets an Imp and every secret of it.
    func remove(_ id: UUID) {
        guard let imp = imp(id) else { return }
        secrets.removeAll(of: imp)
        imps.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(imps) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
