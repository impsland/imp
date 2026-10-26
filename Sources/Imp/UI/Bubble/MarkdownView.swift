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
            ForEach(blocks.indices, id: \.self) { i in block(blocks[i]) }
        }
        .font(.system(size: fontSize))
        .lineSpacing(2)
        // Links to files (a path, often relative to the Imp's folder) open like web links do.
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(Markdown.resolve(url, base: base)) ? .handled : .discarded
        })
    }

    @ViewBuilder private func block(_ block: MarkdownBlock) -> some View {
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
            MarkdownImage(url: Markdown.resolve(url, base: base), alt: alt, link: link, maxHeight: imageHeight, onLoad: onImageLoad)
        case .table(let table):
            MarkdownTable(table: table, fontSize: fontSize - 1)
        case .media(let url, let title, let kind, let autoplay):
            MediaView(url: Markdown.resolve(url, base: base), title: title, kind: kind, owner: mediaOwner,
                      autoplay: autoplay && self.autoplay, measuring: measuring)
        case .rule:
            Divider()
        }
    }
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
    private static let limit = 20

    /// Loads a picture the first time it's asked for. True if it just arrived.
    func load(_ url: URL) async -> Bool {
        guard tried.insert(url).inserted,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return false }
        if images.count >= Self.limit { images.removeAll(); tried.removeAll() }
        images[url] = image
        return true
    }
}
