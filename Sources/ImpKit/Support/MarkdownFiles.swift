import Foundation

/// What a file link in a reply leads to on this device.
public enum FileTarget: Equatable, Sendable {
    /// Not a file (a web address, a mail link, an anchor): left to the system.
    case other(URL)
    /// A file that is here and checked.
    case file(URL)
    /// A file that can't be used, and why.
    case unavailable(WorkspaceReference.Problem)
}

public extension Markdown {
    /// Where a link or picture in a reply leads. `imp-file://` references are resolved by
    /// `WorkspaceReference` (owner's Workspace only, size and checksum checked). Plain paths are
    /// found from `base` as `resolve` does, and must exist.
    static func target(_ url: URL, base: URL, workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) -> FileTarget {
        if WorkspaceReference.isReference(url.absoluteString) {
            guard let named = WorkspaceReference(parsing: url.absoluteString) else { return .unavailable(.malformed) }
            do { return .file(try named.resolve(workspaces: workspaces)) } catch {
                return .unavailable((error as? WorkspaceReference.Problem) ?? .missing)
            }
        }
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return .other(url) }
        guard !url.path(percentEncoded: false).isEmpty else { return .other(url) }
        let file = resolve(url, base: base)
        guard file.isFileURL else { return .other(file) }
        let path = file.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path) ? .file(file) : .unavailable(.missing)
    }

    /// The blocks with every file that can't be used swapped for a line saying so, and links to such
    /// files left as plain text with the reason after them. Pictures and media that are fine get
    /// their final file URL, so the views load them as they are.
    static func checkingFiles(_ blocks: [MarkdownBlock], base: URL, workspaces: (UUID) -> URL = WorkspaceReference.localWorkspaces) -> [MarkdownBlock] {
        blocks.map { block in
            switch block {
            case .image(let url, let alt, let link):
                switch target(url, base: base, workspaces: workspaces) {
                case .unavailable(let why): return missing(name: alt, url: url, why)
                case .file(let file): return .image(url: file, alt: alt, link: link)
                case .other: return block
                }
            case .media(let url, let title, let kind, let autoplay):
                switch target(url, base: base, workspaces: workspaces) {
                case .unavailable(let why): return missing(name: title, url: url, why)
                case .file(let file): return .media(url: file, title: title, kind: kind, autoplay: autoplay)
                case .other: return block
                }
            case .paragraph(let text): return .paragraph(checkingLinks(text, base: base, workspaces: workspaces))
            case .heading(let level, let text): return .heading(level: level, checkingLinks(text, base: base, workspaces: workspaces))
            case .listItem(let marker, let depth, let text):
                return .listItem(marker: marker, depth: depth, checkingLinks(text, base: base, workspaces: workspaces))
            case .quote(let text): return .quote(checkingLinks(text, base: base, workspaces: workspaces))
            default: return block
            }
        }
    }

    private static func missing(name: String, url: URL, _ why: WorkspaceReference.Problem) -> MarkdownBlock {
        // The parser stands in an object character for a missing description.
        let given = name.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return .paragraph(AttributedString(unavailable(name: given.isEmpty ? shortName(url) : given, why)))
    }

    /// "“report.pdf”: This file isn't there any more."
    static func unavailable(name: String, _ why: WorkspaceReference.Problem) -> String {
        let reason = why.errorDescription ?? ""
        return String(localized: "“\(name)”: \(reason)")
    }

    private static func shortName(_ url: URL) -> String {
        let path = WorkspaceReference(parsing: url.absoluteString)?.path ?? url.path(percentEncoded: false)
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? String(localized: "File") : last
    }

    /// A link to a file that can't be used stops being a link and says why.
    private static func checkingLinks(_ text: AttributedString, base: URL, workspaces: (UUID) -> URL) -> AttributedString {
        var broken: [(Range<AttributedString.Index>, WorkspaceReference.Problem)] = []
        for run in text.runs {
            guard let link = run.link, case .unavailable(let why) = target(link, base: base, workspaces: workspaces) else { continue }
            broken.append((run.range, why))
        }
        guard !broken.isEmpty else { return text }
        var out = text
        for (range, why) in broken.reversed() {
            out[range].link = nil
            out.insert(AttributedString(" (\(why.errorDescription ?? ""))"), at: range.upperBound)
        }
        return out
    }
}
