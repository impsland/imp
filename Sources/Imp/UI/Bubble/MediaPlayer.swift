import AVFoundation
import AVKit
import ImpKit
import SwiftUI

/// Audio or video in a reply: a soft, smoky play/pause button for audio, a player for video.
struct MediaView: View {
    let url: URL
    let title: String
    let kind: MarkdownBlock.MediaKind
    /// The answer it belongs to: its player survives the view being rebuilt (the answer growing,
    /// "Read all"), and it starts on its own at most once. Nil (the history): a player of its own.
    let owner: String?
    /// Which of the answer's players it is (0 is the first): marked ones take turns in this order,
    /// and the same file twice gets two players.
    var order = 0
    /// The Imp asked for it to start on its own (`#autoplay`), and that's allowed here.
    let autoplay: Bool
    var measuring = false

    var body: some View {
        if measuring {
            placeholder         // the same size, without loading anything
        } else {
            LoadedMedia(url: url, title: title, kind: kind, owner: owner, order: order, autoplay: autoplay)
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch kind {
        case .audio: AudioRow(title: title, playing: false, time: nil, progress: 0, seek: { _ in }) {}
        case .video: VideoFrame { Color.black.opacity(0.15) }
        }
    }
}

private struct LoadedMedia: View {
    let url: URL
    let title: String
    let kind: MarkdownBlock.MediaKind
    let owner: String?
    let order: Int
    let autoplay: Bool
    @State private var media: Media?

    var body: some View {
        Group {
            switch kind {
            case .audio:
                AudioRow(title: title, playing: media?.isPlaying ?? false, time: media?.time,
                         progress: media?.progress ?? 0, failed: media?.failed ?? false,
                         seek: { media?.seek(to: $0) }) { media?.toggle() }
            case .video:
                VideoFrame {
                    if let media, !media.failed { VideoPlayer(player: media.player) }
                    else { Color.black.opacity(0.15).overlay { if media?.failed == true { Unplayable(title: title) } } }
                }
            }
        }
        .onAppear {
            guard let owner else {
                media = media ?? Media(url: url, slot: nil)
                return
            }
            let m = Playback.shared.acquire(owner: owner, order: order, url: url)
            media = m
            if autoplay { Playback.shared.autoplay(m) }
        }
        .onDisappear {
            // The answer's player stops once no view shows it any more (the bubble closed or
            // moved on); a history player stops with its view.
            if let media, let slot = media.slot { Playback.shared.release(slot.id) } else { media?.stop(); media = nil }
        }
    }
}

/// A video (or a sound in a video's place) that can't be played: the file is missing or not media.
private struct Unplayable: View {
    let title: String

    var body: some View {
        Label(title.isEmpty ? "Can't play this" : "Can't play \(title)", systemImage: "exclamationmark.triangle")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(8)
    }
}

/// The smoky button, what's playing with the time, and a bar to jump around in it.
private struct AudioRow: View {
    let title: String
    let playing: Bool
    let time: String?
    let progress: Double
    var failed = false
    let seek: (Double) -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SmokeButton(playing: playing, action: toggle)
                .disabled(failed)
                .opacity(failed ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title.isEmpty ? "Audio" : title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if failed {
                        Label("Can't play", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(time ?? "–:––").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ScrubBar(progress: progress, seek: seek)
            }
        }
        .frame(height: 44)
    }
}

/// How far along it is. Click anywhere to jump there, or drag to scrub (it jumps on release).
/// Thin until the pointer comes near, then a little thicker with a knob.
private struct ScrubBar: View {
    @Environment(\.impTint) private var tint
    let progress: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = min(max(dragging ?? progress, 0), 1)
            let active = hover || dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint.opacity(0.85)).frame(width: width * shown)
            }
            .frame(height: active ? 5 : 3)
            .overlay(alignment: .leading) {             // the knob doesn't size the bar
                Circle().fill(tint)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: width * shown - 4.5)
                    .opacity(active ? 1 : 0)
            }
            .frame(maxHeight: .infinity)                    // centred in a taller, easier target
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragging = min(max($0.location.x / width, 0), 1) }
                .onEnded { value in
                    seek(min(max(value.location.x / width, 0), 1))
                    dragging = nil
                })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 14)
        .onHover { hover = $0 }
        .help("Click or drag to jump")
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            seek(min(max(progress + (direction == .increment ? 0.1 : -0.1), 0), 1))
        }
    }
}

/// A round button with no edge: a puff of the Imp's colour that drifts and breathes while it plays.
private struct SmokeButton: View {
    @Environment(\.impTint) private var tint
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
                let t = playing ? context.date.timeIntervalSinceReferenceDate : 0
                ZStack {
                    // Three soft blobs, slightly apart: together they read as smoke, not a disc.
                    ForEach(0..<3, id: \.self) { i in
                        let a = t * (0.9 + Double(i) * 0.35) + Double(i) * 2.1
                        Circle()
                            .fill(RadialGradient(colors: [tint.opacity(0.75), tint.opacity(0.3), .clear],
                                                 center: .center, startRadius: 0, endRadius: 17))
                            .frame(width: 34, height: 34)
                            .offset(x: cos(a) * 3, y: sin(a * 1.3) * 3)
                    }
                    .blur(radius: 3.5)
                    .scaleEffect((hover ? 1.08 : 1) * (1 + 0.05 * sin(t * 2.6)))
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: tint.opacity(0.6), radius: 3)
                        .offset(x: playing ? 0 : 1)          // a play triangle looks centred a hair right
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(playing ? "Pause" : "Play")
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// Video at 16:9, sized up front (so measuring the bubble gets its height before anything loads).
private struct VideoFrame<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One file's player and what the UI shows of it. It knows when it plays however it was started
/// (its button, the video's own controls, its turn coming up), so only one thing plays at a time.
@MainActor @Observable
final class Media {
    typealias Slot = MediaQueue<String>.Item

    let player: AVPlayer
    /// Where it sits in an answer (nil: a player of the history's own).
    let slot: Slot?
    /// Playing, or buffering on the way to it. Its answer is told when this changes.
    private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { Playback.shared.changed(self) } }
    }
    /// The answer it belongs to (nil: the history).
    var owner: String? { slot?.owner }
    /// The file is missing or isn't something AVFoundation plays.
    private(set) var failed = false
    /// "0:12 / 0:45" (just the elapsed time until the length is known).
    private(set) var time: String?
    /// 0…1 of the way through (0 until the length is known).
    private(set) var progress: Double = 0
    /// Stopped partway (paused, not at the start): its answer's next one waits for it.
    var isMidway: Bool { !failed && (isPlaying || player.currentTime().seconds > 0.05) }
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var stopped = false

    init(url: URL, slot: Slot?) {
        self.slot = slot
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail() }
        })
        // KVO may call from any thread: hop to the main actor.
        watches.append(player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.syncPlaying() }
        })
        watches.append(item.observe(\.status) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        })
    }

    func toggle() { isPlaying ? pause() : play() }

    /// You started it.
    func play() {
        guard !failed, !stopped else { return }
        Playback.shared.started(self)
        start()
    }

    /// Its turn came up (or it may autoplay).
    func start() {
        guard !failed, !stopped else { return }
        Playback.shared.playing(self)
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// For good (the view went away): silence, and no more callbacks.
    func stop() {
        pause()
        stopped = true
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for o in observers { NotificationCenter.default.removeObserver(o) }
        watches.forEach { $0.invalidate() }
        timeObserver = nil
        observers = []
        watches = []
    }

    /// Jumps to `fraction` of the way through (once the length is known).
    func seek(to fraction: Double) {
        guard let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 else { return }
        progress = fraction                                  // the bar stays where you let go
        player.seek(to: CMTime(seconds: fraction * length, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func ended() {
        isPlaying = false
        player.seek(to: .zero)       // ready to play again
        tick()
        Playback.shared.finished(self)
    }

    private func fail() {
        guard !failed else { return }
        failed = true
        isPlaying = false
        player.pause()
        Playback.shared.failed(self)
    }

    /// Started or paused some other way (a video's own controls): the UI and the others follow.
    private func syncPlaying() {
        guard !stopped else { return }
        let now = player.timeControlStatus != .paused
        guard now != isPlaying else { return }
        isPlaying = now
        if now { Playback.shared.started(self); Playback.shared.playing(self) }
    }

    private func syncStatus() {
        if player.currentItem?.status == .failed { fail() }
    }

    private func tick() {
        let now = player.currentTime().seconds
        let length = player.currentItem?.duration.seconds ?? .nan
        time = length.isFinite ? "\(Self.clock(now)) / \(Self.clock(length))" : Self.clock(now)
        progress = length.isFinite && length > 0 && now.isFinite ? min(max(now / length, 0), 1) : 0
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shared by every bubble: one thing plays at a time, an answer's `#autoplay` players take turns
/// (in the order they're written), each answer's players outlive their views being rebuilt, and
/// each autoplays at most once.
@MainActor
final class Playback {
    static let shared = Playback()
    private weak var current: Media?
    private var autoplayed: Set<String> = []
    private var queue = MediaQueue<String>()
    /// Players of answers on screen, with how many views show each.
    private var owned: [String: (media: Media, views: Int)] = [:]

    /// The answer's player at `order`, made the first time a view asks.
    func acquire(owner: String, order: Int, url: URL) -> Media {
        let key = "\(owner) \(order) \(url.absoluteString)"
        let entry = owned[key] ?? (Media(url: url, slot: .init(id: key, owner: owner, order: order)), 0)
        owned[key] = (entry.media, entry.views + 1)
        return entry.media
    }

    /// A view let go. Once none has picked it up again a moment later, the player stops for good.
    func release(_ key: String) {
        guard let entry = owned[key] else { return }
        owned[key] = (entry.media, entry.views - 1)
        guard entry.views <= 1 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let now = self.owned[key], now.views <= 0 else { return }
            now.media.stop()
            self.owned[key] = nil
            self.queue.remove(key)
        }
    }

    /// Posted (object: the owner) when an answer's player starts or stops playing.
    static let didChange = Notification.Name("ImpPlaybackDidChange")

    /// Something of `owner`'s is playing (or on its way to), or waits its turn: its bubble waits.
    func isPlaying(owner: String) -> Bool {
        (queue.owner == owner && !queue.waiting.isEmpty)
            || owned.values.contains { $0.media.owner == owner && $0.media.isPlaying }
    }

    func changed(_ media: Media) {
        guard let owner = media.owner else { return }
        NotificationCenter.default.post(name: Self.didChange, object: owner)
    }

    /// The Imp asked for `media` to start on its own: the first time only, and after the ones
    /// before it in its answer (if one of those is still going, it waits its turn).
    func autoplay(_ media: Media) {
        guard let slot = media.slot, autoplayed.insert(slot.id).inserted else { return }
        let busy = current.flatMap { $0.isMidway ? $0.slot : nil }
        if queue.autoplay(slot, busy: busy) { media.start() }
    }

    /// You started `media` yourself: what waited in another answer won't start after it.
    func started(_ media: Media) {
        queue.started(media.slot)
    }

    /// `media` starts: whatever else was playing pauses.
    func playing(_ media: Media) {
        if current !== media { current?.pause() }
        current = media
    }

    /// `media` can't play: if it was the one going, its turn passes on; if it was waiting, it no longer does.
    func failed(_ media: Media) {
        if current === media { finished(media) } else if let slot = media.slot { queue.remove(slot.id) }
    }

    /// `media` played to the end (or couldn't): the next one waiting in its answer starts.
    func finished(_ media: Media) {
        guard let slot = media.slot else { return }
        while let next = queue.finished(slot) {
            if let m = owned[next.id]?.media, !m.failed { m.start(); return }
        }
    }
}
