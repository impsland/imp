import AVKit
import ImpDesign
import ImpKit
import QuickLook
import ImageIO
import SwiftUI

/// A reply's Markdown, block by block (ImpKit's parser, the same the Mac's bubble uses): text,
/// headings, lists, quotes, code, tables, and the pictures, voices and videos it shows. Files on
/// the Mac are fetched over the link (`LinkFileStore`); web ones load directly.
struct ReplyBlocks: View {
    var text: String
    var imp: LinkImp
    var hub: LinkHub
    /// A voice marked `#autoplay` starts on its own (only in replies that just arrived).
    var autoplay = false

    var body: some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .tint(Tone.accentBright)
        // A link to a file (a document, a sheet, anything Quick Look shows) is fetched from its home, then previewed.
        .environment(\.openURL, OpenURLAction { url in
            guard !LinkFiles.isWeb(url.absoluteString), url.scheme == nil || WorkspaceReference.isReference(url.absoluteString) else {
                return .systemAction
            }
            open(file: url.absoluteString)
            return .handled
        })
        .quickLookPreview($preview)
        .alert("This file can't be opened", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    @State private var preview: URL?
    @State private var problem: String?

    private func open(file ref: String) {
        Task {
            do { preview = try await hub.files.file(imp: imp.id, ref: ref) }
            catch { problem = error.localizedDescription }
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(s).font(Typeface.body).foregroundStyle(Tone.text)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(s).font(level <= 1 ? Typeface.title : level == 2 ? Typeface.cardTitle : Typeface.label)
                .foregroundStyle(Tone.text).padding(.top, Spacing.hairline)
        case .listItem(let marker, let depth, let s):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                Text(marker ?? "").font(Typeface.body).foregroundStyle(Tone.accent)
                    .frame(minWidth: Spacing.medium, alignment: .trailing)
                Text(s).font(Typeface.body).foregroundStyle(Tone.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let s):
            Text(s).font(Typeface.body).italic().foregroundStyle(Tone.muted)
                .padding(.leading, Spacing.cozy)
                .overlay(alignment: .leading) { Capsule().fill(Tone.accent.opacity(Opacity.dimmed)).frame(width: Stroke.focus + Stroke.hairline) }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(Typeface.mono).foregroundStyle(Tone.text)
                    .padding(Spacing.cozy)
            }
            .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        case .image(let url, let alt, let link):
            PictureBlock(ref: url.absoluteString, alt: alt, link: link, imp: imp, hub: hub)
        case .media(let url, let title, let kind, let auto):
            if kind == .audio {
                AudioBlock(ref: url.absoluteString, title: title, imp: imp, hub: hub, autoplay: auto && autoplay)
            } else {
                VideoBlock(ref: url.absoluteString, title: title, imp: imp, hub: hub)
            }
        case .table(let table):
            TableBlock(table: table)
        case .rule:
            Capsule().fill(Tone.card).frame(height: Spacing.tight).padding(.vertical, Spacing.small)
        }
    }
}

// MARK: - Fetching

/// Loads one file a reply refers to: from the web directly, from the Mac over the link.
@MainActor @Observable
final class ReplyFile {
    enum State { case loading, ready(URL), failed(String) }
    private(set) var state = State.loading
    let ref: String
    let isWeb: Bool

    /// `here`: the file is already on this phone (fetched before), so it is ready from the start.
    init(ref: String, here: URL? = nil) {
        self.ref = ref
        isWeb = LinkFiles.isWeb(ref)
        if let here { state = .ready(here) }
    }

    func load(imp: UUID, hub: LinkHub) async {
        if isWeb, let url = URL(string: ref) { state = .ready(url); return }
        if case .ready = state { return }
        state = .loading
        do { state = .ready(try await hub.files.file(imp: imp, ref: ref)) }
        catch { state = .failed(error.localizedDescription) }
    }
}

/// A placeholder while a file comes over (with how far along it is), or why it couldn't.
private struct FileStatus: View {
    var file: ReplyFile
    var progress: Double?
    var icon: String
    var label: String
    var retry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: icon).font(.icon(.big)).foregroundStyle(Tone.accent).frame(width: Sizing.glyph)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(label).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                switch file.state {
                case .failed: EmptyView()
                default:
                    if let progress, progress > 0 {
                        ProgressView(value: progress).tint(Tone.accent)
                    } else {
                        Text("Getting it from your Mac…").font(Typeface.small).foregroundStyle(Tone.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            if case .failed(let why) = file.state {
                IssueBadge(text: why)
                Button(action: retry) { Image(systemName: "arrow.clockwise").font(.icon(.large, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tone.accentBright).accessibilityLabel("Try Again")
                    .frame(minWidth: Sizing.hit, minHeight: Sizing.hit).contentShape(Rectangle())
            }
        }
        .padding(Spacing.medium)
        .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
}

// MARK: - Pictures

/// A picture in a reply, in a box of its final size from the first frame. The chat is a lazy list: rows that
/// scroll away are dropped and built again when they come back. A picture that started as a short "getting
/// it" line and grew once decoded changed the height of what was above you, and the chat jumped. Now the
/// box keeps the picture's proportions (read from the file's header, which needs no decoding) or, before
/// the file is here at all, a usual photo's; and a decoded picture is kept in memory, so a row built again
/// shows it at once.
private struct PictureBlock: View {
    var ref: String
    var alt: String
    var link: URL?
    var imp: LinkImp
    var hub: LinkHub

    init(ref: String, alt: String, link: URL?, imp: LinkImp, hub: LinkHub) {
        self.ref = ref; self.alt = alt; self.link = link; self.imp = imp; self.hub = hub
        // Already on the phone: ready, its proportions now, and the picture too if it was shown before.
        let here = LinkFiles.isWeb(ref) ? nil : hub.files.cached(imp: imp.id, ref: ref)
        _file = State(initialValue: ReplyFile(ref: ref, here: here))
        _image = State(initialValue: here.flatMap(PictureMemory.shared.image(at:)))
        _aspect = State(initialValue: here.flatMap(PictureMemory.shared.aspect(at:)))
    }
    @State private var file: ReplyFile
    @State private var image: UIImage?
    /// Width over height, once known. Until then the box has a usual photo's.
    @State private var aspect: CGFloat?
    @Environment(\.openURL) private var openURL

    /// A box no taller than half a column, the shape of the picture.
    private static let maxHeight = Sizing.column / 2
    private static let usualAspect: CGFloat = 4 / 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        Color.clear
            .aspectRatio(aspect ?? Self.usualAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Self.maxHeight)
            .overlay {
                if let image {
                    // A UIKit view: the source the full-screen picture zooms out of and back into (`PictureViewer`).
                    ChatPicture(image: image, label: alt.isEmpty ? String(localized: "Picture") : alt, share: shareURL,
                                opens: link.map { url in { openURL(url) } })
                        .contentShape(shape)
                        .contextMenu {
                            Button { UIPasteboard.general.image = image } label: { Label("Copy", systemImage: "doc.on.doc") }
                            if case .ready(let url) = file.state, url.isFileURL {
                                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                            }
                        }
                } else {
                    FileStatus(file: file, progress: hub.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                               icon: "photo", label: alt.isEmpty ? String(localized: "Picture") : alt) { Task { await load() } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tone.well, in: shape)
                }
            }
            .task(id: ref) { if image == nil { await load() } }
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, hub: hub)
        guard case .ready(let url) = f.state else { return }
        let loaded: UIImage?
        if url.isFileURL {
            loaded = await PictureMemory.shared.load(url)
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            loaded = UIImage(data: data)?.preparingForDisplay()
        } else {
            loaded = nil
        }
        guard let loaded else { return }
        // Only a picture whose shape wasn't known yet changes the box: once, the first time it comes.
        if aspect == nil, loaded.size.height > 0 { aspect = loaded.size.width / loaded.size.height }
        image = loaded
    }

    /// What Share hands on: the file on this phone, or the picture's address on the web.
    private var shareURL: URL? {
        if case .ready(let url) = file.state { return url }
        return nil
    }
}

/// Pictures from replies, decoded once and kept while there is memory for them, and their proportions,
/// read from a file's header alone (no decoding), so a picture's box has its size before the picture does.
@MainActor
final class PictureMemory {
    static let shared = PictureMemory()

    private let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()
    private var aspects: [URL: CGFloat] = [:]

    /// The picture, if it was decoded before.
    func image(at url: URL) -> UIImage? { images.object(forKey: url as NSURL) }

    /// Width over height, from the file's header. Nil for a file that isn't a picture.
    func aspect(at url: URL) -> CGFloat? {
        if let known = aspects[url] { return known }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = info[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = info[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 are turned a quarter: the picture shows as tall as the file is wide.
        if let orientation = info[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) { swap(&width, &height) }
        aspects[url] = width / height
        return width / height
    }

    /// Decodes the picture off the main thread (once), ready to draw.
    func load(_ url: URL) async -> UIImage? {
        if let known = image(at: url) { return known }
        let decoded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        if let decoded { images.setObject(decoded, forKey: url as NSURL) }
        return decoded
    }
}

// MARK: - Sound

/// A voice or a song: play, pause, scrub.
private struct AudioBlock: View {
    var ref: String
    var title: String
    var imp: LinkImp
    var hub: LinkHub
    var autoplay: Bool

    init(ref: String, title: String, imp: LinkImp, hub: LinkHub, autoplay: Bool) {
        self.ref = ref; self.title = title; self.imp = imp; self.hub = hub; self.autoplay = autoplay
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var player = PlayerModel()

    var body: some View {
        Group {
            if case .ready(let url) = file.state {
                HStack(spacing: Spacing.medium) {
                    Button { player.toggle(url) } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.icon(.big, weight: .bold))
                            .foregroundStyle(Tone.onAccent)
                            .frame(width: Sizing.hit, height: Sizing.hit)
                            .background(Circle().fill(Tone.accent))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(title.isEmpty ? url.deletingPathExtension().lastPathComponent : title)
                            .font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                        Slider(value: Binding(get: { player.progress }, set: { player.seek(to: $0, url: url) }))
                            .impSlider()
                            .controlSize(.mini)
                        HStack {
                            Text(PlayerModel.clock(player.elapsed))
                            Spacer()
                            Text(PlayerModel.clock(player.duration))
                        }
                        .font(Typeface.small.monospacedDigit()).foregroundStyle(Tone.muted)
                    }
                }
                .padding(Spacing.medium)
                .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .contextMenu {
                    if url.isFileURL { ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") } }
                }
            } else {
                FileStatus(file: file, progress: hub.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                           icon: "waveform", label: title.isEmpty ? String(localized: "Sound") : title) { Task { await load() } }
            }
        }
        .task(id: ref) { await load() }
        .onDisappear { player.leave() }
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, hub: hub)
        guard case .ready(let url) = f.state else { return }
        await player.measure(url)
        // Its turn comes after any voice that is talking (on the stage too), never over it.
        if autoplay { player.autoplay(url) }
    }
}

/// One AVPlayer for a block, with what the controls show. It shares the stage's voice (`StageVoice`):
/// starting it pauses whatever else plays, and the other way round.
@MainActor @Observable
final class PlayerModel: StageVoicePlayer {
    /// Nothing the stage's bubbles own: this is the chat's.
    var owner: String? { nil }
    @ObservationIgnored private let key = "chat|\(UUID().uuidString)"

    private(set) var isPlaying = false
    private(set) var elapsed = 0.0
    private(set) var duration = 0.0
    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var ended: NSObjectProtocol?

    func toggle(_ url: URL) {
        if isPlaying { pause(); return }
        begin(url)
    }

    /// A reply that just arrived speaks in its turn (once): after whatever is talking now.
    func autoplay(_ url: URL) {
        StageVoice.shared.ready(key: key, owner: nil) { [weak self] in
            self?.begin(url)
            return self != nil
        }
    }

    private func begin(_ url: URL) {
        prepare(url)
        // Plays out loud even with the ring switch on silent, like any media app.
        StageVoice.activateSession()
        StageVoice.shared.started(self)
        if progress >= 0.999 { player?.seek(to: .zero) }
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        StageVoice.shared.stopped(self)
    }

    /// Something else started.
    func yield() {
        player?.pause()
        isPlaying = false
    }

    /// Its block went away: it stops, and gives up its turn.
    func leave() {
        player?.pause()
        isPlaying = false
        StageVoice.shared.cancel(key: key)
        StageVoice.shared.finished(self)
    }

    /// Reads how long it is before it's played (the controls show it right away).
    func measure(_ url: URL) async {
        guard duration == 0, let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite else { return }
        duration = d
    }

    func seek(to fraction: Double, url: URL) {
        prepare(url)
        guard duration > 0 else { return }
        elapsed = fraction * duration
        player?.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
    }

    private func prepare(_ url: URL) {
        guard player == nil else { return }
        let p = AVPlayer(url: url)
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds
                if let d = p.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem,
                                                       queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                StageVoice.shared.finished(self)
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Video

private struct VideoBlock: View {
    var ref: String
    var title: String
    var imp: LinkImp
    var hub: LinkHub

    init(ref: String, title: String, imp: LinkImp, hub: LinkHub) {
        self.ref = ref; self.title = title; self.imp = imp; self.hub = hub
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var clip: StageClip?

    var body: some View {
        // One 16:9 box whether the video is here yet or not, so the row never changes height (see `PictureBlock`).
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { video }
        .task(id: ref) { await load() }
        .onDisappear { clip?.pause() }
    }

    @ViewBuilder private var video: some View {
        Group {
            if let clip {
                // Playing it (its own controls) pauses whatever else talks.
                PlayerSurface(player: clip.player)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                    .contextMenu {
                        if case .ready(let url) = file.state, url.isFileURL {
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                    }
                    .accessibilityLabel(title.isEmpty ? String(localized: "Video") : title)
            } else {
                FileStatus(file: file, progress: hub.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                           icon: "film", label: title.isEmpty ? String(localized: "Video") : title) { Task { await load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            }
        }
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, hub: hub)
        if case .ready(let url) = f.state, clip == nil {
            clip = StageClip(url: url, kind: .video, key: "chat|\(UUID().uuidString)", owner: nil)
        }
    }
}

// MARK: - Tables

private struct TableBlock: View {
    var table: MarkdownBlock.Table

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { i, cell in
                        Text(cell).font(Typeface.caption.weight(.bold)).foregroundStyle(Tone.text)
                            .gridColumnAlignment(alignment(i))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(Typeface.caption).foregroundStyle(Tone.text)
                        }
                    }
                }
            }
            .padding(Spacing.cozy)
        }
        .background(Tone.well, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
