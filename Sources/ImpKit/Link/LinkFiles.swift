import Foundation

/// Which files a phone may fetch from the Mac, and where they are. A reply on the phone shows a
/// picture or plays a voice that lives on the Mac (`![](voice.mp3)`, a path in the Imp's folder);
/// the phone asks for it by the reference as written. The Mac only sends what one of that Imp's
/// replies actually mentions, so a paired phone can't read anything else on the Mac.
public enum LinkFiles {
    /// The file a reference means, on this Mac: relative to the Imp's folder (`base`), absolute,
    /// `~/…` or a `file:` URL. Nil for web addresses (the phone loads those itself) and junk.
    public static func resolve(_ ref: String, base: URL) -> URL? {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        let url = URL(string: ref) ?? URL(fileURLWithPath: ref)
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return nil }
        // The Imp's folder is a folder: relative paths go inside it, not beside it.
        let folder = URL(fileURLWithPath: base.path(percentEncoded: false), isDirectory: true)
        let resolved = Markdown.resolve(url, base: folder)
        guard resolved.isFileURL else { return nil }
        // A fragment (`#autoplay`) isn't part of the file.
        return URL(fileURLWithPath: resolved.path(percentEncoded: false)).standardizedFileURL
    }

    /// Whether some reply mentions `ref` (as written, or with its %-escapes undone).
    public static func isMentioned(_ ref: String, in texts: [String]) -> Bool {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ref.count >= 3 else { return false }
        let forms = Set([ref, ref.removingPercentEncoding ?? ref, ref.components(separatedBy: "#").first ?? ref].filter { $0.count >= 3 })
        return texts.contains { text in forms.contains { text.contains($0) } }
    }

    /// Whether a reference points at the web (the phone loads it directly).
    public static func isWeb(_ ref: String) -> Bool {
        guard let scheme = URL(string: ref)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
