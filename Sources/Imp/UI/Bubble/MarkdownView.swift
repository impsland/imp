import AppKit
import ImpKit
import SwiftUI

/// A reply drawn from its Markdown: paragraphs, headings, lists, quotes, code, tables and pictures.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// The Imp's own folder: links and pictures given as paths are found from here.
    let base: URL
    var fontSize: CGFloat = 14
    /// A picture finished loading, so the bubble must be measured again. Nil: don't load (measuring).
    var onImageLoad: (() -> Void)?
    /// Where pictures and videos sit, from this view's top (reported while measuring).
    var onMedia: (([ReadAllCut.Span]) -> Void)?
    /// The answer this belongs to (its audio and video keep playing while it's redrawn). Nil in the history.
    var mediaOwner: String?
    /// Audio and video the Imp marked `#autoplay` may start on their own.
    var autoplay = false
    /// Measuring the bubble: nothing loads.
    var measuring = false
    /// The tallest a picture gets.
    var imageHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let orders = Self.mediaOrders(blocks)
            ForEach(blocks.indices, id: \.self) { i in block(blocks[i], order: orders[i]) }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(MediaSpans.self) { spans in MainActor.assumeIsolated { onMedia?(spans) } }
        .font(.system(size: fontSize))
        .lineSpacing(2)
        // Links to files (a path, often relative to the Imp's folder) open like web links do.
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(Markdown.resolve(url, base: base)) ? .handled : .discarded
        })
    }

    private static let space = "markdown"

    /// Reports where a picture or video sits, for cutting the reply short between blocks.
    private func reporting<V: View>(_ view: V) -> some View {
        view.background(GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.space))
            Color.clear.preference(key: MediaSpans.self, value: [.init(top: frame.minY, bottom: frame.maxY)])
        })
    }

    /// Each block's place among the reply's audio and video (0 for the first one, and for other blocks).
    private static func mediaOrders(_ blocks: [MarkdownBlock]) -> [Int] {
        var next = 0
        return blocks.map { block in
            guard case .media = block else { return 0 }
            defer { next += 1 }
            return next
        }
    }

    @ViewBuilder private func block(_ block: MarkdownBlock, order: Int) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text).font(.system(size: fontSize + CGFloat(max(3 - level, 0)) * 2, weight: level <= 2 ? .bold : .semibold))
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker ?? "").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(text)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let text):
            Text(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let code):
            Text(code)
                .font(.system(size: fontSize - 1.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .image(let url, let alt, let link):
            reporting(MarkdownImage(url: Markdown.resolve(url, base: base), alt: alt, link: link, maxHeight: imageHeight, onLoad: onImageLoad))
                .frame(maxWidth: .infinity, alignment: .center)     // pictures sit in the middle; text stays left
        case .table(let table):
            MarkdownTable(table: table, fontSize: fontSize - 1)
        case .media(let url, let title, let kind, let autoplay):
            reporting(MediaView(url: Markdown.resolve(url, base: base), title: title, kind: kind, owner: mediaOwner,
                                order: order, autoplay: autoplay && self.autoplay, measuring: measuring))
        case .rule:
            Divider()
        }
    }
}

/// The pictures' and videos' extents, collected up the tree.
private struct MediaSpans: PreferenceKey {
    static let defaultValue: [ReadAllCut.Span] = []
    static func reduce(value: inout [ReadAllCut.Span], nextValue: () -> [ReadAllCut.Span]) { value += nextValue() }
}

private struct MarkdownTable: View {
    let table: MarkdownBlock.Table
    let fontSize: CGFloat

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { c in
                    Text(table.header[c]).fontWeight(.semibold).gridColumnAlignment(alignment(c))
                }
            }
            Divider()
            ForEach(table.rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(table.rows[r].indices, id: \.self) { c in Text(table.rows[r][c]) }
                }
            }
        }
        .font(.system(size: fontSize))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A picture once it's loaded; until then (or if it can't be), its description. Clicking either
/// opens the picture, or where it links to (links resolve like the reply's other links).
private struct MarkdownImage: View {
    @Environment(\.openURL) private var openURL
    let url: URL
    let alt: String
    let link: URL?
    let maxHeight: CGFloat
    let onLoad: (() -> Void)?

    var body: some View {
        Button { openURL(link ?? url) } label: { picture }
            .buttonStyle(.plain)
            .help(link.map { "Open \($0.absoluteString)" } ?? "Open the picture")
    }

    @ViewBuilder private var picture: some View {
        if let image = RemoteImages.shared.images[url] {
            FittedImage(size: image.size, maxHeight: maxHeight) {
                Image(nsImage: image).resizable().clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel(alt)
        } else {
            Label(alt.isEmpty ? "Image" : alt, systemImage: "photo")
                .foregroundStyle(.secondary)
                .task(id: url) {
                    guard let onLoad, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
                    if await RemoteImages.shared.load(url) { onLoad() }
                }
        }
    }
}

/// Shrinks a picture to the width it's offered and at most `maxHeight`, keeping its shape;
/// never enlarges it. (Sized up front, so measuring the bubble gets its real height.)
private struct FittedImage: Layout {
    let size: CGSize
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let width = proposal.width ?? size.width
        let scale = min(width / size.width, maxHeight / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Pictures from replies, loaded once and kept for a while (shared by every Imp's bubble).
@MainActor @Observable
final class RemoteImages {
    static let shared = RemoteImages()
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var tried = Set<URL>()
    /// Kept, oldest first: the oldest goes when there are too many (never all at once, so a reply
    /// with many pictures doesn't keep losing and reloading them).
    @ObservationIgnored private var order: [URL] = []
    private static let limit = 60

    /// Loads a picture the first time it's asked for. True if it just arrived.
    func load(_ url: URL) async -> Bool {
        guard tried.insert(url).inserted else { return false }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return false }
        while order.count >= Self.limit {
            let oldest = order.removeFirst()
            images[oldest] = nil
            tried.remove(oldest)
        }
        images[url] = image
        order.append(url)
        return true
    }
}
