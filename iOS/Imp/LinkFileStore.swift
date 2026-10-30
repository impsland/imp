import CryptoKit
import Foundation
import ImpKit
import Observation

/// Files that replies show, fetched from the Mac on demand: a picture an Imp drew, a voice another
/// Imp recorded, a video, a document it saved. They live on the Mac (in the Imp's folder), so the
/// phone asks for each by the reference the reply uses and the Mac streams it over the link in
/// parts. Kept in the cache afterwards; the same reference asked twice at once is fetched once.
@MainActor @Observable
final class LinkFileStore {
    enum Failure: LocalizedError {
        case offline, refused(String), lost
        var errorDescription: String? {
            switch self {
            case .offline: String(localized: "Your Mac isn't around")
            case .refused(let why): why
            case .lost: String(localized: "The connection to your Mac dropped. Try again.")
            }
        }
    }

    /// How far along each fetch is (0…1), by `key(imp:ref:)`.
    private(set) var progress: [String: Double] = [:]

    @ObservationIgnored private unowned let client: LinkClient
    @ObservationIgnored private var transfers: [UUID: Transfer] = [:]
    @ObservationIgnored private var byKey: [String: UUID] = [:]

    private final class Transfer {
        let key: String
        let folder: URL
        var handle: FileHandle?
        var partial: URL?
        var waiting: [CheckedContinuation<URL, Error>] = []
        init(key: String, folder: URL) { self.key = key; self.folder = folder }
    }

    init(client: LinkClient) { self.client = client }

    nonisolated static func key(imp: UUID, ref: String) -> String { "\(imp.uuidString)|\(ref)" }

    /// Where a reference's file is kept: one folder per reference, the file inside under its own name.
    private static func folder(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL.cachesDirectory.appending(path: "LinkFiles/\(hash)", directoryHint: .isDirectory)
    }

    /// Already here from an earlier fetch.
    func cached(imp: UUID, ref: String) -> URL? {
        let folder = Self.folder(for: Self.key(imp: imp, ref: ref))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// The file on this phone, fetching it from the Mac if needed.
    func file(imp: UUID, ref: String) async throws -> URL {
        if let url = cached(imp: imp, ref: ref) { return url }
        let key = Self.key(imp: imp, ref: ref)
        return try await withCheckedThrowingContinuation { c in
            if let id = byKey[key], let t = transfers[id] { t.waiting.append(c); return }
            let id = UUID()
            let t = Transfer(key: key, folder: Self.folder(for: key))
            t.waiting.append(c)
            transfers[id] = t
            byKey[key] = id
            progress[key] = 0
            if !client.requestFile(id, imp: imp, ref: ref) { finish(id, .failure(Failure.offline)) }
        }
    }

    func received(_ part: LinkFilePart, for id: UUID) {
        guard let t = transfers[id] else { return }
        do {
            if t.handle == nil {
                let fm = FileManager.default
                try? fm.removeItem(at: t.folder)
                try fm.createDirectory(at: t.folder, withIntermediateDirectories: true)
                let partial = t.folder.appending(path: ".partial")
                fm.createFile(atPath: partial.path, contents: nil)
                t.partial = partial
                t.handle = try FileHandle(forWritingTo: partial)
            }
            try t.handle?.write(contentsOf: part.data)
            progress[t.key] = part.size > 0 ? Double(part.offset + part.data.count) / Double(part.size) : 1
            guard part.isLast, let partial = t.partial else { return }
            try t.handle?.close()
            t.handle = nil
            // Its own name keeps its type (players and Quick Look go by the extension).
            let name = part.name.isEmpty ? "file" : (part.name as NSString).lastPathComponent
            let final = t.folder.appending(path: name)
            try FileManager.default.moveItem(at: partial, to: final)
            finish(id, .success(final))
        } catch {
            finish(id, .failure(error))
        }
    }

    func failed(_ id: UUID, reason: String) { finish(id, .failure(Failure.refused(reason))) }

    /// The link went down: every fetch in flight fails (they can be tried again).
    func linkLost() {
        for id in Array(transfers.keys) { finish(id, .failure(Failure.lost)) }
    }

    private func finish(_ id: UUID, _ result: Result<URL, Error>) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        byKey[t.key] = nil
        progress[t.key] = nil
        try? t.handle?.close()
        if case .failure = result { try? FileManager.default.removeItem(at: t.folder) }
        t.waiting.forEach { $0.resume(with: result) }
    }
}
