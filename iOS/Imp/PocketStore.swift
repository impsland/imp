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
        imps = (try? Data(contentsOf: url)).map(PocketImp.decodeAll) ?? []
        for imp in imps { secrets.migrateLegacyHeaders(of: imp) }
    }

    func imp(_ id: UUID) -> PocketImp? { imps.first { $0.id == id } }

    func contains(_ id: UUID) -> Bool { imps.contains { $0.id == id } }

    func add(_ imp: PocketImp) {
        guard !contains(imp.id) else { return }
        imps.append(imp)
        persist()
    }

    /// Changes an Imp. The values of headers it no longer has are forgotten.
    func update(_ id: UUID, _ change: (inout PocketImp) -> Void) {
        guard let i = imps.firstIndex(where: { $0.id == id }) else { return }
        let before = imps[i].servers
        change(&imps[i])
        for server in before {
            let now = imps[i].servers.first { $0.id == server.id }
            let kept = Set((now?.headers ?? []).map { $0.lowercased() })
            for name in server.headers where !kept.contains(name.lowercased()) { secrets.remove(.header(server.id, name), imp: id) }
            if now == nil { secrets.remove(.legacyHeader(server.id), imp: id) }
        }
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
