import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A file in an Imp's Workspace that can be named from anywhere: the owner Imp, the path inside its
/// Workspace, and what the file should be (size, SHA-256, type). Written as
///
///     imp-file://<owner-imp-uuid>/<path>?size=<bytes>&sha256=<64 hex>&type=<mime>
///
/// A bare relative path only means something to the Imp whose Workspace it is relative to, so the
/// moment a text leaves its Imp (a message to another Imp, a reply carried back) its file
/// references are rewritten to this form (`canonicalize`). Every reader resolves it the same way:
/// `resolve` finds the owner's Workspace, refuses anything that is not a plain path inside it
/// (absolute paths, `..`, links out), and checks size and checksum before the file is used.
/// The rules are shared with other clients by `Tests/Fixtures/workspace-refs.json`.
public struct WorkspaceReference: Equatable, Sendable {
    public static let scheme = "imp-file"
    /// Files up to this size get a checksum when a reference is made (bigger ones carry the size only).
    public static let checksumLimit = 32 * 1024 * 1024
    static let maxPathBytes = 1024
    static let maxDepth = 32

    public var owner: UUID
    /// Relative to the owner's Workspace, `/`-separated, normalised (see `normalize`).
    public var path: String
    public var size: Int?
    /// Lowercase hex.
    public var sha256: String?
    /// A MIME type, as a hint for previews.
    public var type: String?
    /// `#autoplay` and the like: kept for the player, not part of the file.
    public var fragment: String?

    /// Why a file can't be used. Every case reads as a sentence for the person looking at the chat.
    public enum Problem: LocalizedError, Equatable, Sendable {
        case malformed, outsideWorkspace, otherDevice, missing, notAFile, changed

        public var errorDescription: String? {
            switch self {
            case .malformed: String(localized: "This file link is broken, so the file can't be opened.")
            case .outsideWorkspace: String(localized: "This file is outside the Imp's own folder, so it isn't opened.")
            case .otherDevice: String(localized: "This file is on another device and isn't here to open.")
            case .missing: String(localized: "This file isn't there any more.")
            case .notAFile: String(localized: "This isn't a file that can be opened.")
            case .changed: String(localized: "This file changed after it was shared, so it isn't opened.")
            }
        }
    }

    public init(owner: UUID, path: String, size: Int? = nil, sha256: String? = nil, type: String? = nil, fragment: String? = nil) {
        self.owner = owner; self.path = path; self.size = size; self.sha256 = sha256; self.type = type; self.fragment = fragment
    }

    // MARK: Writing and reading

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func escape(_ s: String, keeping extra: String = "") -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: extra))) ?? ""
    }

    /// The reference as text, ready for a Markdown destination (no spaces or parentheses).
    public var string: String {
        var out = "\(Self.scheme)://\(owner.uuidString)/\(Self.escape(path, keeping: "/"))"
        var query: [String] = []
        if let size { query.append("size=\(size)") }
        if let sha256 { query.append("sha256=\(sha256)") }
        if let type { query.append("type=\(Self.escape(type, keeping: "/"))") }
        if !query.isEmpty { out += "?" + query.joined(separator: "&") }
        if let fragment, !fragment.isEmpty { out += "#" + Self.escape(fragment) }
        return out
    }

    /// Whether `ref` is written in this form (valid or not).
    public static func isReference(_ ref: String) -> Bool {
        ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(scheme + ":")
    }

    /// Reads a reference. Nil unless it is well formed: the scheme, an owner id, a normalised path
    /// (see `normalize`), and any size, checksum and type it gives being sane. Nothing is looked up.
    public init?(parsing ref: String) {
        let text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isReference(text), let parts = URLComponents(string: text), parts.scheme?.lowercased() == Self.scheme,
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host, let owner = UUID(uuidString: host) else { return nil }
        let raw = parts.percentEncodedPath
        guard raw.hasPrefix("/"), let decoded = String(raw.dropFirst()).removingPercentEncoding,
              let path = Self.normalize(decoded), path == decoded else { return nil }
        var size: Int?, sha: String?, type: String?
        var seen = Set<String>()
        for item in parts.percentEncodedQueryItems ?? [] {
            guard seen.insert(item.name).inserted, let value = item.value?.removingPercentEncoding else { return nil }
            switch item.name {
            case "size":
                guard let n = Int(value), n >= 0, String(n) == value else { return nil }
                size = n
            case "sha256":
                guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
                sha = value
            case "type":
                guard !value.isEmpty, value.count <= 127, value.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else { return nil }
                type = value
            default:
                return nil
            }
        }
        let fragment = parts.percentEncodedFragment.flatMap { $0.removingPercentEncoding }
        self.init(owner: owner, path: path, size: size, sha256: sha, type: type, fragment: fragment)
    }

    // MARK: Paths

    /// A path as a reference carries it: relative, `/`-separated, no `.`, empty or `..` parts,
    /// no `\\`, NUL or control characters, a sane length. Nil for anything else (and for `~`).
    public static func normalize(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.count <= maxPathBytes, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "\\" }) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, parts.count <= maxDepth, !parts.contains("..") else { return nil }
        let kept = parts.filter { $0 != "." }
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }

    /// The path inside `root` that a plain reference (the way a reply writes one) means: relative
    /// to `root`, absolute inside it, or a `file:` URL. `..` may be used as long as it stays inside.
    /// Nil for web addresses, junk, and anything that points outside `root`, however it is spelled.
    /// This is lexical, except that an absolute path is also tried with symlinks resolved.
    public static func relativePath(of ref: String, in root: URL) -> String? {
        var text = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text) {
            if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }
            text = url.path(percentEncoded: false)
        }
        if text.hasPrefix("~") { text = NSString(string: text).expandingTildeInPath }
        guard !text.isEmpty, !text.contains("\0") else { return nil }
        guard let base = lexical(root.path(percentEncoded: false)) else { return nil }
        if !text.hasPrefix("/") {
            guard let inside = lexical(base + "/" + text), let rel = inside.relative(to: base) else { return nil }
            return normalize(rel)
        }
        if let inside = lexical(text), let rel = inside.relative(to: base) { return normalize(rel) }
        let real = LinkFiles.real(URL(fileURLWithPath: text)).path(percentEncoded: false)
        let realRoot = LinkFiles.real(root).path(percentEncoded: false)
        return real.relative(to: realRoot).flatMap(normalize)
    }

    /// An absolute path with `.`, `..` and doubled slashes taken out. Nil if `..` climbs above `/`.
    private static func lexical(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if parts.popLast() == nil { return nil } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Finding the file

    /// Where `workspaces` keeps an Imp's Workspace by default: this device's.
    public static let localWorkspaces: @Sendable (UUID) -> URL = { Workspace.directory(for: $0) }

    /// The file this reference names inside `root` (the owner's Workspace), nothing checked but
    /// that it stays inside. No lookup of the file itself.
    public func url(in root: URL) -> URL {
        var url = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: true)
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    /// The file, found and checked: inside the owner's Workspace even through links, a regular
    /// file, and (when the reference says so) the size and checksum it was shared with.
    public func resolve(workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) throws -> URL {
        let root = workspaces(owner)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue else {
            throw Problem.otherDevice
        }
        let file = url(in: root)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { throw Problem.missing }
        guard LinkFiles.isInside(file, folder: root) else { throw Problem.outsideWorkspace }
        try verify(file)
        return file
    }

    /// Whether `file` is a regular file of the size and checksum this reference gives.
    public func verify(_ file: URL) throws {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw Problem.missing
        }
        guard values.isRegularFile == true, let actual = values.fileSize else { throw Problem.notAFile }
        if let size, size != actual { throw Problem.changed }
        guard let sha256 else { return }
        // Checked once per version of the file: its place, inode, size and change times to the nanosecond.
        var info = stat()
        guard stat(file.path(percentEncoded: false), &info) == 0 else { throw Problem.missing }
        let key = "\(file.path(percentEncoded: false))|\(info.st_ino)|\(actual)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
            + "|\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)|\(sha256)"
        if Self.checked.contains(key) { return }
        guard let found = Self.checksum(of: file), found == sha256 else { throw Problem.changed }
        Self.checked.insert(key)
    }

    // MARK: Making one

    /// The reference for a file in `owner`'s Workspace `root`. `ref` is how a reply wrote it. Nil
    /// unless it names an existing regular file inside `root`.
    public static func make(owner: UUID, ref: String, in root: URL) -> WorkspaceReference? {
        guard let path = relativePath(of: ref, in: root) else { return nil }
        var made = WorkspaceReference(owner: owner, path: path)
        let file = made.url(in: root)
        guard LinkFiles.isInside(file, folder: root),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return nil }
        made.size = size
        if size <= checksumLimit { made.sha256 = checksum(of: file) }
        made.type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        if let hash = URL(string: ref.trimmingCharacters(in: .whitespacesAndNewlines))?.fragment, !hash.isEmpty { made.fragment = hash }
        return made
    }

    /// Rewrites the file references in `text` that name files in `owner`'s Workspace into the form
    /// every Imp can resolve. Anything else (web addresses, files elsewhere, files that are gone)
    /// stays as written.
    public static func canonicalize(_ text: String, owner: UUID, root: URL) -> String {
        guard text.contains("](") || text.contains("src=") || text.contains("href=") else { return text }
        var out = text
        for range in LinkFiles.referenceRanges(in: text).reversed() {
            let ref = String(text[range])
            guard !LinkFiles.isWeb(ref), !isReference(ref), let made = make(owner: owner, ref: ref, in: root) else { continue }
            out.replaceSubrange(range, with: made.string)
        }
        return out
    }

    /// `canonicalize` for an Imp of this device.
    public static func canonicalize(_ text: String, owner: UUID) -> String {
        canonicalize(text, owner: owner, root: Workspace.directory(for: owner))
    }

    // MARK: Checksums

    /// SHA-256 of a file, as lowercase hex, read in pieces. Nil if it can't be read.
    public static func checksum(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // At the end the read gives nil or nothing.
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func checksum(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Files already checked (path, time, size and checksum), so a chat redrawn doesn't read them again.
    private static let checked = Checked()

    private final class Checked: @unchecked Sendable {
        private let lock = NSLock()
        private var keys = Set<String>()
        func contains(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
        func insert(_ key: String) {
            lock.withLock {
                if keys.count >= 512 { keys.removeAll() }
                keys.insert(key)
            }
        }
    }
}

private extension String {
    /// What follows `base` + "/" in this absolute path. Nil if it isn't inside `base`.
    func relative(to base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard hasPrefix(prefix), count > prefix.count else { return nil }
        return String(dropFirst(prefix.count))
    }
}
