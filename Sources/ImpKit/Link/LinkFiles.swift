import Foundation

/// Which files a phone may fetch from the Mac, and where they are. A reply on the phone shows a
/// picture or plays a voice that lives on the Mac (`![](voice.mp3)`, a path in the Imp's folder);
/// the phone asks for it by the reference as written. The Mac only sends what one of that Imp's
/// replies actually mentions, so a paired phone can't read anything else on the Mac.
public enum LinkFiles {
    /// The file a reference means, on this Mac: relative to the Imp's folder (`base`), absolute,
    /// `~/…` or a `file:` URL. Nil for web addresses (the phone loads those itself) and junk.
    public static func resolve(_ ref: String, base: URL, workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) -> URL? {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        // `imp-file://<imp>/<path>`: inside that Imp's own Workspace, wherever the reply came from.
        if WorkspaceReference.isReference(ref) {
            guard let named = WorkspaceReference(parsing: ref) else { return nil }
            return named.url(in: workspaces(named.owner)).standardizedFileURL
        }
        let url = URL(string: ref) ?? URL(fileURLWithPath: ref)
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }
        // The Imp's folder is a folder: relative paths go inside it, not beside it.
        let folder = URL(fileURLWithPath: base.path(percentEncoded: false), isDirectory: true)
        let resolved = Markdown.resolve(url, base: folder)
        guard resolved.isFileURL else { return nil }
        // A fragment (`#autoplay`) isn't part of the file.
        return URL(fileURLWithPath: resolved.path(percentEncoded: false)).standardizedFileURL
    }

    /// The references the replies make, as written: Markdown link and image destinations (`](…)`,
    /// with an optional `<…>` and title) and `src=`/`href=` attributes. Plain prose mentioning a path
    /// is not a reference.
    public static func references(in texts: [String]) -> [String] {
        texts.flatMap { text in referenceRanges(in: text).map { String(text[$0]) } }
    }

    /// Where each reference sits in `text`, in the order `references(in:)` lists them.
    public static func referenceRanges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var rest = Substring(text)
        while let open = rest.range(of: "](") {
            rest = rest[open.upperBound...]
            var depth = 1
            var end = rest.startIndex
            var escaped = false
            scan: while end < rest.endIndex {
                let ch = rest[end]
                if escaped { escaped = false } else {
                    switch ch {
                    case "\\": escaped = true
                    case "(": depth += 1
                    case ")": depth -= 1; if depth == 0 { break scan }
                    case "\n": depth = -1; break scan
                    default: break
                    }
                }
                end = rest.index(after: end)
            }
            guard depth == 0 else { continue }
            if let range = destination(in: rest[..<end]) { found.append(range) }
            rest = rest[end...]
        }
        for key in ["src=", "href="] {
            var tail = Substring(text)
            while let r = tail.range(of: key) {
                tail = tail[r.upperBound...]
                guard let quote = tail.first, quote == "\"" || quote == "'" else { continue }
                let body = tail.dropFirst()
                guard let close = body.firstIndex(of: quote) else { break }
                found.append(body.startIndex..<close)
                tail = body[close...]
            }
        }
        return found
    }

    /// The destination of a Markdown link: without `<…>` or a trailing `"title"`.
    private static func destination(in raw: Substring) -> Range<String.Index>? {
        guard let start = raw.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        var range = start..<raw.endIndex
        if raw[start] == "<", let close = raw[start...].firstIndex(of: ">") {
            range = raw.index(after: start)..<close
        } else if let space = raw[start...].firstIndex(where: { $0 == " " || $0 == "\t" }) {
            range = start..<space
        } else if let last = raw.lastIndex(where: { !$0.isWhitespace }) {
            range = start..<raw.index(after: last)
        }
        return range.isEmpty ? nil : range
    }

    /// Where a file really is: standardised, symlinks resolved.
    public static func real(_ url: URL) -> URL {
        // The deepest part that exists is resolved by the system; the rest is only standardised.
        var head = url.standardizedFileURL
        var tail: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        while head.path != "/", realpath(head.path(percentEncoded: false), &buffer) == nil {
            tail.insert(head.lastPathComponent, at: 0)
            head = head.deletingLastPathComponent()
        }
        var path = head.path == "/" ? "/" : String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        for part in tail { path = (path as NSString).appendingPathComponent(part) }
        return URL(fileURLWithPath: path)
    }

    /// Whether `ref` means the very file some reply references (compared after resolving both on
    /// this Mac, so `a/../b.png` and `b.png` are the same, and a prefix of a path is not).
    public static func isMentioned(_ ref: String, base: URL, in texts: [String],
                                   workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) -> Bool {
        guard let wanted = resolve(ref, base: base, workspaces: workspaces).map(real) else { return false }
        return references(in: texts).contains { resolve($0, base: base, workspaces: workspaces).map(real) == wanted }
    }

    /// Whether `url` is inside `folder` (both resolved: a link out of it doesn't count).
    public static func isInside(_ url: URL, folder: URL) -> Bool {
        let path = real(url).path(percentEncoded: false)
        var root = real(folder).path(percentEncoded: false)
        if !root.hasSuffix("/") { root += "/" }
        return path.hasPrefix(root)
    }

    /// Whether a holder may fetch `ref`: a reply references that very file, and for a holder that is
    /// not trusted it is also inside the Imp's own folder (`base`).
    public static func mayServe(_ ref: String, base: URL, in texts: [String], trusted: Bool,
                                workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) -> Bool {
        guard isMentioned(ref, base: base, in: texts, workspaces: workspaces),
              let url = resolve(ref, base: base, workspaces: workspaces) else { return false }
        return trusted || isInside(url, folder: base)
    }

    /// Whether a reference points at the web (the phone loads it directly).
    public static func isWeb(_ ref: String) -> Bool {
        guard let scheme = URL(string: ref)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
