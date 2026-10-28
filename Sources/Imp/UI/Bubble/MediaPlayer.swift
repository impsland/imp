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
    /// The Imp asked for it to start on its own (`#autoplay`), and that's allowed here.
    let autoplay: Bool
    var measuring = false

    var body: some View {
        if measuring {
            placeholder         // the same size, without loading anything
        } else {
            LoadedMedia(url: url, title: title, kind: kind, owner: owner, autoplay: autoplay)
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
    let autoplay: Bool
    @State private var media: Media?

    var body: some View {
        Group {
            switch kind {
            case .audio:
                AudioRow(title: title, playing: media?.isPlaying ?? false, time: media?.time,
                         progress: media?.progress ?? 0, seek: { media?.seek(to: $0) }) { media?.toggle() }
            case .video:
                VideoFrame {
                    if let media { VideoPlayer(player: media.player) } else { Color.black.opacity(0.15) }
                }
            }
        }
        .onAppear {
            guard let key, let owner else {
                media = media ?? Media(url: url)
                return
            }
            let m = Playback.shared.acquire(key, url: url, owner: owner)
            media = m
            if autoplay, Playback.shared.mayAutoplay(key) { m.play() }
        }
        .onDisappear {
            // The answer's player stops once no view shows it any more (the bubble closed or
            // moved on); a history player stops with its view.
            if let key { Playback.shared.release(key) } else { media?.stop() }
        }
    }

    private var key: String? { owner.map { "\($0) \(url.absoluteString)" }
    }
}

/// The smoky button, what's playing with the time, and a bar to jump around in it.
private struct AudioRow: View {
    let title: String
    let playing: Bool
    let time: String?
    let progress: Double
    let seek: (Double) -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SmokeButton(playing: playing, action: toggle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title.isEmpty ? "Audio" : title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(time ?? "–:––").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
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

/// One file's player and what the UI shows of it.
@MainActor @Observable
final class Media {
    let player: AVPlayer
    /// The answer it belongs to (nil: the history), told when it starts or stops playing.
    let owner: String?
    private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { Playback.shared.changed(self) } }
    }
    /// "0:12 / 0:45" (just the elapsed time until the length is known).
    private(set) var time: String?
    /// 0…1 of the way through (0 until the length is known).
    private(set) var progress: Double = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    init(url: URL, owner: String? = nil) {
        player = AVPlayer(url: url)
        self.owner = owner
        // What the player really does, however it got there (a video's own controls, the end of
        // the file): buffering on the way to playing counts as playing.
        statusObserver = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.statusObserver != nil else { return }
                let playing = self.player.timeControlStatus != .paused
                if playing { Playback.shared.playing(self) }
                self.isPlaying = playing
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.player.seek(to: .zero)       // ready to play again
                self?.tick()
            }
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
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
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate()
        statusObserver = nil
        timeObserver = nil
        endObserver = nil
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

/// Shared by every bubble: one thing plays at a time, each answer's players outlive their views
/// being rebuilt, and each autoplays at most once.
@MainActor
final class Playback {
    static let shared = Playback()
    private weak var current: Media?
    private var autoplayed: Set<String> = []
    /// Players of answers on screen, with how many views show each.
    private var owned: [String: (media: Media, views: Int)] = [:]

    /// Posted (object: the owner) when an answer's player starts or stops playing.
    static let didChange = Notification.Name("ImpPlaybackDidChange")

    func acquire(_ key: String, url: URL, owner: String) -> Media {
        let entry = owned[key] ?? (Media(url: url, owner: owner), 0)
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
        }
    }

    /// Something of `owner`'s is playing (or on its way to): its bubble waits.
    func isPlaying(owner: String) -> Bool {
        owned.values.contains { $0.media.owner == owner && $0.media.isPlaying }
    }

    func changed(_ media: Media) {
        guard let owner = media.owner else { return }
        NotificationCenter.default.post(name: Self.didChange, object: owner)
    }

    /// `media` starts: whatever else was playing pauses.
    func playing(_ media: Media) {
        if current !== media { current?.pause() }
        current = media
    }

    /// True the first time it's asked for `key`.
    func mayAutoplay(_ key: String) -> Bool { autoplayed.insert(key).inserted }
}
