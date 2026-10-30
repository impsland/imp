import Foundation

/// An item in the Den: `handle/slug`. Checked on the way in, so what Imp builds a web address from
/// is always plain lowercase letters, digits and dashes.
public struct DenItemID: Hashable, Sendable, CustomStringConvertible {
    public let handle: String
    public let slug: String

    public init?(handle: String, slug: String) {
        guard DenName.isValid(handle, range: 3...32), DenName.isValid(slug, range: 1...48) else { return nil }
        self.handle = handle
        self.slug = slug
    }

    /// From `handle/slug`.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(handle: String(parts[0]), slug: String(parts[1]))
    }

    public var description: String { "\(handle)/\(slug)" }
}

/// Handles and slugs: lowercase letters, digits and dashes between them.
public enum DenName {
    public static func isValid(_ text: String, range: ClosedRange<Int>) -> Bool {
        guard range.contains(text.utf8.count), text.first != "-", text.last != "-" else { return false }
        return text.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }

    /// Plain text as a name: lowercase, accents and other scripts folded to ASCII, runs of anything
    /// else as one dash, at most `limit` characters. Empty when nothing is left.
    public static func slug(_ text: String, limit: Int = 48) -> String {
        let latin = (text.applyingTransform(.toLatin, reverse: false) ?? text)
            .applyingTransform(.stripDiacritics, reverse: false) ?? text
        var out = "", pendingDash = false
        for scalar in latin.lowercased().unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// What the Den tells about an item. Fields the Den leaves out take plain defaults.
public struct DenItem: Decodable, Equatable, Sendable {
    public var handle: String
    public var slug: String
    public var name: String
    public var kind: String
    public var summary: String
    public var tags: [String]
    public var revision: Int
    public var installs: Int
    /// The kit runs programs on the Mac that adds it (MCP servers with a command).
    public var runsPrograms: Bool

    public var id: DenItemID? { DenItemID(handle: handle, slug: slug) }

    private enum Key: String, CodingKey {
        case handle, slug, name, kind, summary, tags, revision, installs
        case runsPrograms = "runs_programs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        handle = try c.decode(String.self, forKey: .handle)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "kit"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        installs = try c.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        runsPrograms = try c.decodeIfPresent(Bool.self, forKey: .runsPrograms) ?? false
    }

    public init(handle: String, slug: String, name: String = "", kind: String = "kit", summary: String = "", tags: [String] = [],
                revision: Int = 1, installs: Int = 0, runsPrograms: Bool = false) {
        self.handle = handle; self.slug = slug; self.name = name; self.kind = kind; self.summary = summary
        self.tags = tags; self.revision = revision; self.installs = installs; self.runsPrograms = runsPrograms
    }

    /// One line for the model: `handle/slug · kind · name · summary · #tags · installs`.
    public var line: String {
        var parts = ["\(handle)/\(slug)", kind]
        if !name.isEmpty { parts.append(name) }
        if !summary.isEmpty { parts.append(summary.count > 140 ? String(summary.prefix(140)) + "…" : summary) }
        if !tags.isEmpty { parts.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        if installs > 0 { parts.append("\(installs) installs") }
        if runsPrograms { parts.append("runs programs") }
        return parts.joined(separator: " · ")
    }
}

/// A page of search results.
public struct DenPage: Decodable, Equatable, Sendable {
    public var items: [DenItem]
    public var nextCursor: String?

    private enum Key: String, CodingKey { case items, nextCursor = "next_cursor" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        items = try c.decodeIfPresent([DenItem].self, forKey: .items) ?? []
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    public init(items: [DenItem], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// An account and what it shared.
public struct DenAccount: Decodable, Equatable, Sendable {
    public var handle: String
    public var items: [DenItem]

    private enum Key: String, CodingKey { case handle, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        handle = try c.decode(String.self, forKey: .handle)
        items = try c.decodeIfPresent([DenItem].self, forKey: .items) ?? []
    }

    public init(handle: String, items: [DenItem] = []) {
        self.handle = handle
        self.items = items
    }
}

/// A new account: the token is shown once and never logged.
public struct DenNewAccount: Decodable, Sendable {
    public var handle: String
    public var token: String
}

/// What a search asks for. Anything left nil isn't filtered on.
public struct DenQuery: Equatable, Sendable {
    public static let kinds = ["imp", "animation", "trigger", "tool", "kit"]
    public static let sorts = ["new", "popular"]

    public var text: String?
    public var kind: String?
    public var tag: String?
    public var sort: String?
    public var limit = 10
    public var cursor: String?

    public init(text: String? = nil, kind: String? = nil, tag: String? = nil, sort: String? = nil, limit: Int = 10, cursor: String? = nil) {
        self.text = text; self.kind = kind; self.tag = tag; self.sort = sort; self.limit = limit; self.cursor = cursor
    }
}

/// What the Den says when it refuses: a problem (RFC 9457, `application/problem+json`).
public struct DenError: LocalizedError, Equatable, Sendable {
    /// The HTTP status. 0 when the answer wasn't a usable one at all.
    public var status: Int
    public var title: String
    public var detail: String?
    /// How long to wait before trying again, from `Retry-After`.
    public var retryAfter: TimeInterval?

    public init(status: Int, title: String, detail: String? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status; self.title = title; self.detail = detail; self.retryAfter = retryAfter
    }

    public var errorDescription: String? {
        if let detail, !detail.isEmpty { return detail }
        guard let retryAfter, status == 429 else { return title }
        return title + " " + String(localized: "Try again in \(Int(retryAfter.rounded(.up))) seconds.")
    }

    public var isConflict: Bool { status == 409 }

    /// Reads an error answer. Whatever the body is, there's an error to show.
    static func read(status: Int, body: Data, retryAfter header: String?) -> DenError {
        struct Problem: Decodable { var title: String?; var detail: String? }
        let problem = try? JSONDecoder().decode(Problem.self, from: body)
        let wait = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }.map { max(0, $0) }
        let title = problem?.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "The Den answered \(status).")
        return DenError(status: status, title: title, detail: problem?.detail, retryAfter: wait)
    }

    static let unreadable = DenError(status: 0, title: String(localized: "The Den sent an answer Imp can't read."))
    static let tooLarge = DenError(status: 0, title: String(localized: "The Den sent more than Imp will accept."))
}
