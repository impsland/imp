import Foundation

/// One block of a Markdown reply, ready to draw. Inline styling (bold, italic, code, links)
/// stays in the attributed strings.
public enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    /// `marker` is "•", "◦" or "3."; nil for a later paragraph of the same item. `depth` 0 is top level.
    case listItem(marker: String?, depth: Int, AttributedString)
    case quote(AttributedString)
    case code(String)
    /// `url` as written: resolve it with `Markdown.resolve` before loading. `link` is where a
    /// picture wrapped in a link (`[![alt](pic)](link)`) points; clicking any other picture opens it.
    case image(url: URL, alt: String, link: URL?)
    case table(Table)
    case rule
    /// Audio or video, embedded like a picture: `![title](voice.mp3)`. `#autoplay` on the file
    /// (`voice.mp3#autoplay`) asks for it to start on its own; it's stripped from `url`.
    case media(url: URL, title: String, kind: MediaKind, autoplay: Bool)

    public enum MediaKind: Equatable, Sendable {
        case audio, video

        /// By file extension (what AVFoundation plays).
        public init?(_ url: URL) {
            switch url.pathExtension.lowercased() {
            case "mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac": self = .audio
            case "mp4", "m4v", "mov": self = .video
            default: return nil
            }
        }
    }

    public struct Table: Equatable {
        public enum Alignment: Equatable { case leading, center, trailing }
        public var alignments: [Alignment]
        public var header: [AttributedString]
        public var rows: [[AttributedString]]
    }
}

public enum Markdown {
    /// Parses a reply into blocks. Anything unparseable shows as one plain paragraph.
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let doc = try? AttributedString(markdown: keepingLineBreaks(markingLinkedImages(text)), options: options) else {
            return [.paragraph(AttributedString(text))]
        }
        var blocks: [MarkdownBlock] = []
        var table: (id: Int, value: MarkdownBlock.Table)?
        /// Pictures and players found in the table's cells: they follow the table (a cell is too small for them).
        var tableEmbeds: [MarkdownBlock] = []
        var startedItems = Set<Int>()

        func flushTable() {
            guard var t = table?.value else { return }
            let columns = t.alignments.count
            t.header = padded(t.header, to: columns)
            t.rows = t.rows.map { padded($0, to: columns) }
            blocks.append(.table(t))
            blocks.append(contentsOf: tableEmbeds)
            table = nil
            tableEmbeds = []
        }

        for (intent, range) in doc.runs[\.presentationIntent] {
            var content = AttributedString(doc[range])
            content.presentationIntent = nil
            let parts = intent?.components ?? []

            if let tablePart = parts.first(where: { if case .table = $0.kind { true } else { false } }),
               case .table(let columns) = tablePart.kind {
                if table?.id != tablePart.identity {
                    flushTable()
                    table = (tablePart.identity, .init(alignments: columns.map(alignment), header: [], rows: []))
                }
                tableEmbeds += liftingEmbeds(content).embeds
                var column = 0, row: Int?
                for part in parts {
                    switch part.kind {
                    case .tableCell(let c): column = c
                    case .tableRow(let r): row = r
                    default: break
                    }
                }
                if let row {
                    while table!.value.rows.count < row { table!.value.rows.append([]) }
                    table!.value.rows[row - 1] = placing(content, at: column, in: table!.value.rows[row - 1])
                } else {
                    table!.value.header = placing(content, at: column, in: table!.value.header)
                }
                continue
            }
            flushTable()

            let lists = parts.filter { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }
            switch parts.first?.kind {
            case .codeBlock?:
                var code = String(content.characters)
                if code.hasSuffix("\n") { code.removeLast() }
                blocks.append(.code(code))
            case .header(let level)?:
                let (text, embeds) = liftingEmbeds(content)
                blocks.append(.heading(level: level, text))
                blocks.append(contentsOf: embeds)
            case .thematicBreak?:
                blocks.append(.rule)
            default:
                if let item = parts.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = item.kind {
                    let depth = max(lists.count - 1, 0)
                    var marker: String?
                    if startedItems.insert(item.identity).inserted {
                        if case .orderedList? = lists.first?.kind { marker = "\(ordinal)." }
                        else { marker = depth == 0 ? "•" : "◦" }
                    }
                    // A picture or player in an item sits right under it (a list of voice notes).
                    let (text, embeds) = liftingEmbeds(content)
                    // An item that's only a player is the player (no lone bullet above it).
                    if embeds.isEmpty || !text.characters.allSatisfy(\.isWhitespace) {
                        blocks.append(.listItem(marker: marker, depth: depth, text))
                    }
                    blocks.append(contentsOf: embeds)
                } else if parts.contains(where: { $0.kind == .blockQuote }) {
                    let (text, embeds) = liftingEmbeds(content)
                    if !text.characters.allSatisfy(\.isWhitespace) { blocks.append(.quote(text)) }
                    blocks.append(contentsOf: embeds)
                } else {
                    blocks.append(contentsOf: splittingImages(content))
                }
            }
        }
        flushTable()
        return blocks
    }

    /// Where a link or picture in a reply points. Paths become file URLs: absolute, `~/…`, or
    /// relative to `base` (the Imp's own folder, where its commands run). URLs stay as they are.
    public static func resolve(_ url: URL, base: URL) -> URL {
        guard url.scheme == nil else { return url }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty else { return url }
        if path.hasPrefix("~") { return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }

    /// Foundation's parser keeps only the link of a linked picture and drops the picture. So,
    /// before parsing, `[![alt](pic)](link)` becomes a picture whose URL carries both (outside
    /// code fences); `splittingImages` takes them apart again.
    static let linkedImage = "imp-linked-image"
    private static let linkedImagePattern = try! NSRegularExpression(pattern: #"\[!\[([^\]]*)\]\(([^)\s]+)\)\]\(([^)\s]+)\)"#)

    static func markingLinkedImages(_ text: String) -> String {
        guard text.contains("[![") else { return text }
        var fenced = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return line }
            guard !fenced else { return line }
            let ns = line as NSString
            var out = line
            for match in linkedImagePattern.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                var c = URLComponents()
                c.scheme = linkedImage
                c.path = "x"
                c.queryItems = [URLQueryItem(name: "src", value: ns.substring(with: match.range(at: 2))),
                                URLQueryItem(name: "href", value: ns.substring(with: match.range(at: 3)))]
                guard let marked = c.url?.absoluteString else { continue }
                let replacement = "![\(ns.substring(with: match.range(at: 1)))](\(marked))"
                out = (out as NSString).replacingCharacters(in: match.range, with: replacement)
            }
            return out
        }.joined(separator: "\n")
    }

    /// Chat replies mean a single newline as a line break; CommonMark would fold it into a space.
    /// So end each line outside code fences with a hard break (two spaces).
    static func keepingLineBreaks(_ text: String) -> String {
        var fenced = false
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return String(line) }
            return fenced || trimmed.isEmpty ? String(line) : line + "  "
        }.joined(separator: "\n")
    }

    /// Images get their own block; the text around them stays paragraphs.
    private static func splittingImages(_ content: AttributedString) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var text = AttributedString()
        func flushText() {
            let chars = text.characters
            if let first = chars.firstIndex(where: { !$0.isWhitespace }), let last = chars.lastIndex(where: { !$0.isWhitespace }) {
                blocks.append(.paragraph(AttributedString(text[first...last])))
            }
            text = AttributedString()
        }
        for (url, range) in content.runs[\.imageURL] {
            if let url {
                flushText()
                blocks.append(embed(url, alt: String(content[range].characters)))
            } else {
                text.append(content[range])
            }
        }
        flushText()
        return blocks
    }

    /// Text that can't hold a picture (a list item, quote, heading or table cell) keeps its words;
    /// its pictures and players come out as blocks of their own, in order.
    static func liftingEmbeds(_ content: AttributedString) -> (text: AttributedString, embeds: [MarkdownBlock]) {
        guard content.runs[\.imageURL].contains(where: { $0.0 != nil }) else { return (content, []) }
        var text = AttributedString()
        var embeds: [MarkdownBlock] = []
        for (url, range) in content.runs[\.imageURL] {
            if let url { embeds.append(embed(url, alt: String(content[range].characters))) } else { text.append(content[range]) }
        }
        let chars = text.characters
        if let first = chars.firstIndex(where: { !$0.isWhitespace }), let last = chars.lastIndex(where: { !$0.isWhitespace }) {
            text = AttributedString(text[first...last])
        } else {
            text = AttributedString()
        }
        return (text, embeds)
    }

    /// A picture, or audio or video by its file's extension (a linked one plays; its link is dropped).
    private static func embed(_ url: URL, alt: String) -> MarkdownBlock {
        if url.scheme == linkedImage, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let picture = parts.first(where: { $0.name == "src" })?.value.flatMap(URL.init(string:)) {
            if MarkdownBlock.MediaKind(picture) != nil { return embed(picture, alt: alt) }
            return .image(url: picture, alt: alt, link: parts.first(where: { $0.name == "href" })?.value.flatMap(URL.init(string:)))
        }
        guard let kind = MarkdownBlock.MediaKind(url) else { return .image(url: url, alt: alt, link: nil) }
        let autoplay = url.fragment?.lowercased() == "autoplay"
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return .media(url: c?.url ?? url, title: alt, kind: kind, autoplay: autoplay)
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownBlock.Table.Alignment {
        switch column.alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private static func placing(_ cell: AttributedString, at column: Int, in row: [AttributedString]) -> [AttributedString] {
        var row = padded(row, to: column + 1)
        row[column] = cell
        return row
    }

    private static func padded(_ row: [AttributedString], to count: Int) -> [AttributedString] {
        row.count >= count ? row : row + Array(repeating: AttributedString(), count: count - row.count)
    }
}
