import CryptoKit
import Foundation
import ImpKit
import Observation

/// Files that replies show, fetched from the Imp's home on demand: a picture an Imp drew, a voice another
/// Imp recorded, a video, a document it saved. They live on the home (in the Imp's folder), so the
/// phone asks for each by the reference the reply uses and the home streams it over the link in
/// parts. Kept in the cache afterwards; the same reference asked twice at once is fetched once.
@MainActor @Observable
final class LinkFileStore {
    enum Failure: LocalizedError {
        case offline, refused(String), lost, tooBig, badPart
        var errorDescription: String? {
            switch self {
            case .offline: String(localized: "Its home isn't around")
            case .refused(let why): why
            case .lost: String(localized: "The connection dropped. Try again.")
            case .tooBig: String(localized: "That file is too big for this iPhone.")
            case .badPart: String(localized: "The file didn't arrive in one piece. Try again.")
            }
        }
    }

    /// How far along each fetch is (0…1), by `key(imp:ref:)`.
    private(set) var progress: [String: Double] = [:]

    @ObservationIgnored private unowned let hub: LinkHub
    @ObservationIgnored private var transfers: [UUID: Transfer] = [:]
    @ObservationIgnored private var byKey: [String: UUID] = [:]

    /// The biggest file taken, whatever its home says it is (about 1 GB).
    nonisolated static let biggest = 1_000_000_000

    private final class Transfer {
        let key: String
        let folder: URL
        /// The device it was asked of: the only one whose parts count.
        let home: UUID
        /// Bytes written so far: the next part has to start there.
        var written = 0
        var handle: FileHandle?
        var partial: URL?
        var waiting: [CheckedContinuation<URL, Error>] = []
        init(key: String, folder: URL, home: UUID) { self.key = key; self.folder = folder; self.home = home }
    }

    init(hub: LinkHub) { self.hub = hub }

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

    /// The file on this phone, fetching it from the Imp's home if needed.
    func file(imp: UUID, ref: String) async throws -> URL {
        if let url = cached(imp: imp, ref: ref) { return url }
        let key = Self.key(imp: imp, ref: ref)
        return try await withCheckedThrowingContinuation { c in
            if let id = byKey[key], let t = transfers[id] { t.waiting.append(c); return }
            let id = UUID()
            guard let home = hub.requestFile(id, imp: imp, ref: ref) else { return c.resume(throwing: Failure.offline) }
            let t = Transfer(key: key, folder: Self.folder(for: key), home: home)
            t.waiting.append(c)
            transfers[id] = t
            byKey[key] = id
            progress[key] = 0
        }
    }

    func received(_ part: LinkFilePart, for id: UUID, from device: UUID) {
        // Parts count from the home it was asked of, in order, of a file of a sane size.
        guard let t = transfers[id], device == t.home else { return }
        guard part.size <= Self.biggest else { return finish(id, .failure(Failure.tooBig)) }
        guard part.offset == t.written, part.size >= 0, t.written + part.data.count <= max(part.size, 0) else {
            return finish(id, .failure(Failure.badPart))
        }
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
            t.written += part.data.count
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

    func failed(_ id: UUID, reason: String, from device: UUID) {
        guard transfers[id]?.home == device else { return }
        finish(id, .failure(Failure.refused(reason)))
    }

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
