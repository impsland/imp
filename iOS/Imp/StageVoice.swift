import AVFoundation
import AVKit
import ImpKit
import Observation
import SwiftUI

/// Something that can be heard, so the stage can keep it from talking over anything else.
@MainActor
protocol StageVoicePlayer: AnyObject {
    /// The speech it belongs to (nil: a player in the chat).
    var owner: String? { get }
    /// Something else started: pause, keeping the place.
    func yield()
    /// How loud it is right now, 0…1 (0 while it doesn't play).
    func level(at t: Double) -> Double
}

extension StageVoicePlayer {
    func level(at t: Double) -> Double { 0 }
}

/// Who may talk: at most one voice or video plays at a time, across the whole phone (the stage's
/// bubbles and the chat share this).
///
/// A voice an Imp marked `#autoplay` takes its turn: it queues first in, first out, in order of
/// arrival (a speech reserves its places when it arrives, a place is taken up once the file is
/// here), so Imps talking back and forth are heard one after another. A voice plays once on its
/// own (it's keyed by speech and file); to hear it again, tap it. Starting something by hand
/// pauses whatever plays, and the queue goes on afterwards.
///
/// Only the presentation is serialized. The Imps' thinking never waits for a voice: an answer goes
/// back to the asking Imp at once as text (a brain must never stall on the screen, or on a phone
/// in your pocket). The queue plays the voices in turn, and a bubble stays up until its voice has
/// finished (plus the normal linger, see `linger(over:)`).
@MainActor @Observable
final class StageVoice {
    static let shared = StageVoice()

    private struct Entry {
        var key: String
        var owner: String?
        /// Starts it, saying whether it did. Nil until its file is here.
        var start: (() -> Bool)?
    }

    /// How long a place waits for its file before the others go ahead.
    private static let fileWait: TimeInterval = 30

    @ObservationIgnored private weak var current: (any StageVoicePlayer)?
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var played: Set<String> = []

    // MARK: Taking turns

    /// `player` is playing now (started by hand or by its turn): whatever else played pauses.
    func started(_ player: any StageVoicePlayer) {
        let before = current
        current = player
        if let before, before !== player { before.yield() }
    }

    /// `player` paused. The queue waits: pausing is a choice.
    func stopped(_ player: any StageVoicePlayer) {
        if current === player { current = nil }
    }

    /// `player` played to its end, or can't play: the next voice in the queue goes.
    func finished(_ player: any StageVoicePlayer) {
        stopped(player)
        pump()
    }

    /// A speech with voices has arrived: they take their places in the queue now, in order of
    /// arrival, though their files may take a while. `canLoad` says which refs this phone can fetch.
    func expect(_ speech: LinkSpeech, canLoad: (String) -> Bool) {
        guard speech.role == .reply, speech.text.contains("](") else { return }
        let owner = speech.id.uuidString
        for case .media(let url, _, _, true) in Markdown.blocks(speech.text) {
            let ref = url.absoluteString
            let key = Self.key(speech: speech.id, ref: ref)
            guard canLoad(ref), !played.contains(key), !entries.contains(where: { $0.key == key }) else { continue }
            entries.append(Entry(key: key, owner: owner))
            // A file that never comes must not hold the others up.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.fileWait))
                self?.expire(key)
            }
        }
    }

    /// The file for `key` is here: its turn comes in order. `start` plays it (false: it can't).
    func ready(key: String, owner: String?, start: @escaping () -> Bool) {
        guard !played.contains(key) else { return }
        if let i = entries.firstIndex(where: { $0.key == key }) {
            entries[i].start = start
        } else {
            entries.append(Entry(key: key, owner: owner, start: start))
        }
        pump()
    }

    /// Its file won't come (or its view is gone): it leaves the queue.
    func cancel(key: String) {
        entries.removeAll { $0.key == key }
        pump()
    }

    /// A speech went away (dismissed, replaced, its Imp left): its voices leave the queue and stop.
    func drop(owner: String) {
        entries.removeAll { $0.owner == owner }
        if let current, current.owner == owner {
            self.current = nil
            current.yield()
        }
        pump()
    }

    /// The app leaves the screen: everything stops, and old turns are forgotten.
    func interrupt() {
        entries.removeAll()
        let playing = current
        current = nil
        playing?.yield()
    }

    /// Whether the speech still has a voice playing or waiting (its bubble stays up for it).
    func holds(_ owner: String) -> Bool {
        current?.owner == owner || entries.contains { $0.owner == owner }
    }

    /// The speech's voice, if it's the one playing: whether and how loud (for its bubble's rim).
    func level(owner: String, at t: Double) -> (playing: Bool, level: Double) {
        guard let current, current.owner == owner else { return (false, 0) }
        return (true, current.level(at: t))
    }

    private func expire(_ key: String) {
        guard let i = entries.firstIndex(where: { $0.key == key }), entries[i].start == nil else { return }
        entries.remove(at: i)
        pump()
    }

    /// Starts the first in line when nobody is talking. A head still waiting for its file holds
    /// the line (it was first); one whose player is gone is skipped.
    private func pump() {
        while current == nil, let head = entries.first {
            guard let start = head.start else { return }
            entries.removeFirst()
            if played.count > 500 { played.removeAll() }
            played.insert(head.key)
            if start() { return }
        }
    }

    static func key(speech: UUID, ref: String) -> String { "\(speech.uuidString)|\(ref)" }

    // MARK: Speech and sound

    /// How long a reply stays up to be read: about 4 s and 0.04 s a character, at most 18.
    static func linger(_ speech: LinkSpeech) -> TimeInterval {
        min(18, 4 + Double(speech.question.count + speech.text.count) * 0.04)
    }

    /// Waits as long as `speech` should stay up: the linger, and, if its voice is still playing or
    /// waiting then, until it has finished and the linger again. Throws when cancelled.
    func linger(over speech: LinkSpeech) async throws {
        let base = Self.linger(speech)
        try await Task.sleep(for: .seconds(base))
        let owner = speech.id.uuidString
        let began = Date()
        var waited = false
        while holds(owner), Date().timeIntervalSince(began) < 600 {
            waited = true
            try await Task.sleep(for: .milliseconds(500))
        }
        if waited { try await Task.sleep(for: .seconds(base)) }
    }

    /// Plays out loud even with the ring switch on silent, like any media app.
    static func activateSession(video: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: video ? .moviePlayback : .default)
        try? session.setActive(true)
    }
}

// MARK: - One clip

/// One voice or video of a speech bubble (or of the chat's video): an AVPlayer that tells the
/// stage when it plays, however it was started (its orb, the video's own controls, its turn).
@MainActor @Observable
final class StageClip: StageVoicePlayer {
    let key: String
    let owner: String?
    let kind: MarkdownBlock.MediaKind
    let player: AVPlayer
    /// Playing, or buffering on the way to it.
    private(set) var isPlaying = false
    /// The file isn't something AVFoundation plays.
    private(set) var failed = false

    @ObservationIgnored private var envelope: VoiceEnvelope?
    @ObservationIgnored private var atEnd = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watch: NSKeyValueObservation?

    init(url: URL, kind: MarkdownBlock.MediaKind, key: String, owner: String?) {
        self.key = key
        self.owner = owner
        self.kind = kind
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended() }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail() }
        })
        // KVO may call from any thread: hop to the main actor.
        watch = player.observe(\.timeControlStatus) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.sync() }
        }
        if kind == .audio, url.isFileURL {
            Task { [weak self] in
                let measured = await Task.detached(priority: .utility) { Self.measure(url) }.value
                self?.envelope = measured
            }
        } else if kind == .video {
            StageVoice.activateSession(video: true)
        }
    }

    /// How loud it is right now, 0…1. A voice that couldn't be measured (streamed from the web)
    /// gets a made-up one that moves like speech.
    func level(at t: Double) -> Double {
        guard isPlaying, !failed else { return 0 }
        guard let envelope else { return VoiceEnvelope.speechLike(at: t) }
        return envelope.level(at: player.currentTime().seconds)
    }

    /// You tapped it: pause, or play (again).
    func toggle() { isPlaying ? pause() : play() }

    /// You started it: whatever else plays, pauses.
    func play() { _ = begin() }

    /// Starts it (its turn, or you); false when it can't play.
    func begin() -> Bool {
        guard !failed else { return false }
        StageVoice.activateSession(video: kind == .video)
        StageVoice.shared.started(self)
        if atEnd { player.seek(to: .zero); atEnd = false }
        player.play()
        isPlaying = true
        return true
    }

    func pause() {
        player.pause()
        isPlaying = false
        StageVoice.shared.stopped(self)
    }

    func yield() {
        player.pause()
        isPlaying = false
    }

    /// Its bubble went away: stop, give up its turn, and let the next voice go.
    func leave() {
        player.pause()
        isPlaying = false
        StageVoice.shared.cancel(key: key)
        StageVoice.shared.finished(self)
    }

    private func sync() {
        let on = player.timeControlStatus != .paused
        guard on != isPlaying else { return }
        isPlaying = on
        if on { StageVoice.shared.started(self) } else { StageVoice.shared.stopped(self) }
    }

    private func ended() {
        atEnd = true
        isPlaying = false
        StageVoice.shared.finished(self)
    }

    private func fail() {
        failed = true
        isPlaying = false
        StageVoice.shared.finished(self)
    }

    /// Reads the whole file once, ~30 loudness frames a second (at most an hour of it), like the
    /// Mac does.
    nonisolated private static func measure(_ url: URL) -> VoiceEnvelope? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let window = AVAudioFrameCount(max(format.sampleRate / 30, 64))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return nil }
        let rate = format.sampleRate / Double(window)
        var rms: [Double] = []
        while file.framePosition < file.length, rms.count < Int(rate * 3600) {
            guard (try? file.read(into: buffer, frameCount: window)) != nil, buffer.frameLength > 0,
                  let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength), n = max(Int(format.channelCount), 1)
            rms.append((0..<n).map { VoiceEnvelope.rms(UnsafeBufferPointer(start: channels[$0], count: count)) }.reduce(0, +) / Double(n))
        }
        return rms.isEmpty ? nil : VoiceEnvelope(rms: rms, rate: rate)
    }
}
