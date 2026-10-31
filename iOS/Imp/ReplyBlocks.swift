import AVKit
import ImpKit
import QuickLook
import SwiftUI

/// A reply's Markdown, block by block (ImpKit's parser, the same the Mac's bubble uses): text,
/// headings, lists, quotes, code, tables, and the pictures, voices and videos it shows. Files on
/// the Mac are fetched over the link (`LinkFileStore`); web ones load directly.
struct ReplyBlocks: View {
    var text: String
    var imp: LinkImp
    var client: LinkClient
    /// A voice marked `#autoplay` starts on its own (only in replies that just arrived).
    var autoplay = false

    var body: some View {
        let blocks = Markdown.blocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .tint(Dungeon.flame)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(s).font(.system(.body, design: .rounded)).foregroundStyle(Dungeon.cream)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let s):
            Text(s).font(.system(level <= 1 ? .title3 : level == 2 ? .headline : .subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Dungeon.cream).padding(.top, 2)
        case .listItem(let marker, let depth, let s):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker ?? "").font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.ember)
                    .frame(minWidth: 12, alignment: .trailing)
                Text(s).font(.system(.body, design: .rounded)).foregroundStyle(Dungeon.cream)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        case .quote(let s):
            Text(s).font(.system(.body, design: .rounded)).italic().foregroundStyle(Dungeon.muted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Capsule().fill(Dungeon.ember.opacity(0.6)).frame(width: 3) }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).foregroundStyle(Dungeon.cream)
                    .padding(10)
            }
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .image(let url, let alt, let link):
            PictureBlock(ref: url.absoluteString, alt: alt, link: link, imp: imp, client: client)
        case .media(let url, let title, let kind, let auto):
            if kind == .audio {
                AudioBlock(ref: url.absoluteString, title: title, imp: imp, client: client, autoplay: auto && autoplay)
            } else {
                VideoBlock(ref: url.absoluteString, title: title, imp: imp, client: client)
            }
        case .table(let table):
            TableBlock(table: table)
        case .rule:
            Rectangle().fill(Dungeon.cardEdge).frame(height: 1).padding(.vertical, 4)
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

    init(ref: String) {
        self.ref = ref
        isWeb = LinkFiles.isWeb(ref)
    }

    func load(imp: UUID, client: LinkClient) async {
        if isWeb, let url = URL(string: ref) { state = .ready(url); return }
        if case .ready = state { return }
        state = .loading
        do { state = .ready(try await client.files.file(imp: imp, ref: ref)) }
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
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Dungeon.ember).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Dungeon.cream).lineLimit(1)
                switch file.state {
                case .failed: EmptyView()
                default:
                    if let progress, progress > 0 {
                        ProgressView(value: progress).tint(Dungeon.ember)
                    } else {
                        Text("Getting it from your Mac…").font(.system(.caption, design: .rounded)).foregroundStyle(Dungeon.muted)
                    }
                }
            }
            Spacer(minLength: 0)
            if case .failed(let why) = file.state {
                IssueBadge(text: why)
                Button(action: retry) { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)) }
                    .foregroundStyle(Dungeon.flame).accessibilityLabel("Try Again")
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Pictures

private struct PictureBlock: View {
    var ref: String
    var alt: String
    var link: URL?
    var imp: LinkImp
    var client: LinkClient

    init(ref: String, alt: String, link: URL?, imp: LinkImp, client: LinkClient) {
        self.ref = ref; self.alt = alt; self.link = link; self.imp = imp; self.client = client
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var image: UIImage?
    @State private var preview: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { tapped() }
                    .contextMenu {
                        Button { UIPasteboard.general.image = image } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if case .ready(let url) = file.state, url.isFileURL {
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                    }
                    .accessibilityLabel(alt.isEmpty ? String(localized: "Picture") : alt)
            } else {
                FileStatus(file: file, progress: client.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                           icon: "photo", label: alt.isEmpty ? String(localized: "Picture") : alt) { Task { await load() } }
            }
        }
        .task(id: ref) { await load() }
        .quickLookPreview($preview)
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, client: client)
        guard case .ready(let url) = f.state else { return }
        if url.isFileURL {
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
        }
    }

    private func tapped() {
        if let link { openURL(link); return }
        if case .ready(let url) = file.state {
            if url.isFileURL { preview = url } else { openURL(url) }
        }
    }
}

// MARK: - Sound

/// A voice or a song: play, pause, scrub.
private struct AudioBlock: View {
    var ref: String
    var title: String
    var imp: LinkImp
    var client: LinkClient
    var autoplay: Bool

    init(ref: String, title: String, imp: LinkImp, client: LinkClient, autoplay: Bool) {
        self.ref = ref; self.title = title; self.imp = imp; self.client = client; self.autoplay = autoplay
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var player = PlayerModel()

    var body: some View {
        Group {
            if case .ready(let url) = file.state {
                HStack(spacing: 12) {
                    Button { player.toggle(url) } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Dungeon.deep)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom)))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.isEmpty ? url.deletingPathExtension().lastPathComponent : title)
                            .font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Dungeon.cream).lineLimit(1)
                        Slider(value: Binding(get: { player.progress }, set: { player.seek(to: $0, url: url) }))
                            .tint(Dungeon.ember)
                            .controlSize(.mini)
                        HStack {
                            Text(PlayerModel.clock(player.elapsed))
                            Spacer()
                            Text(PlayerModel.clock(player.duration))
                        }
                        .font(.system(.caption2, design: .rounded).monospacedDigit()).foregroundStyle(Dungeon.muted)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contextMenu {
                    if url.isFileURL { ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") } }
                }
            } else {
                FileStatus(file: file, progress: client.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                           icon: "waveform", label: title.isEmpty ? String(localized: "Sound") : title) { Task { await load() } }
            }
        }
        .task(id: ref) { await load() }
        .onDisappear { player.leave() }
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, client: client)
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
    var client: LinkClient

    init(ref: String, title: String, imp: LinkImp, client: LinkClient) {
        self.ref = ref; self.title = title; self.imp = imp; self.client = client
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var clip: StageClip?

    var body: some View {
        Group {
            if let clip {
                // Playing it (its own controls) pauses whatever else talks.
                VideoPlayer(player: clip.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contextMenu {
                        if case .ready(let url) = file.state, url.isFileURL {
                            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        }
                    }
                    .accessibilityLabel(title.isEmpty ? String(localized: "Video") : title)
            } else {
                FileStatus(file: file, progress: client.files.progress[LinkFileStore.key(imp: imp.id, ref: ref)],
                           icon: "film", label: title.isEmpty ? String(localized: "Video") : title) { Task { await load() } }
            }
        }
        .task(id: ref) { await load() }
        .onDisappear { clip?.pause() }
    }

    private func load() async {
        let f = file
        await f.load(imp: imp.id, client: client)
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
                        Text(cell).font(.system(.footnote, design: .rounded, weight: .bold)).foregroundStyle(Dungeon.cream)
                            .gridColumnAlignment(alignment(i))
                    }
                }
                Rectangle().fill(Dungeon.cardEdge).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.cream)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
