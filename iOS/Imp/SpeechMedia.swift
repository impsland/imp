import AVKit
import ImpKit
import SwiftUI

/// A voice in a speech bubble: the Imp is heard speaking, so there is no player, only a puff of
/// smoke in its colours that swells with the loudness (tap it to pause or play again). The voice
/// takes its turn in the stage's queue (`StageVoice`) when the Imp marked it `#autoplay`.
struct BubbleVoice: View {
    var ref: String
    var title: String
    var auto: Bool
    var speech: UUID
    var speaker: LinkImp
    var client: LinkClient

    init(ref: String, title: String, auto: Bool, speech: UUID, speaker: LinkImp, client: LinkClient) {
        self.ref = ref; self.title = title; self.auto = auto; self.speech = speech; self.speaker = speaker; self.client = client
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var clip: StageClip?

    var body: some View {
        let failed = clip?.failed ?? { if case .failed = file.state { true } else { false } }()
        HStack(spacing: 8) {
            StageOrb(clip: clip, hue: speaker.hue, failed: failed)
            Text(title.isEmpty ? String(localized: "Voice") : title)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .task(id: ref) { await load() }
        .onDisappear { clip?.leave() }
    }

    private func load() async {
        let key = StageVoice.key(speech: speech, ref: ref)
        await file.load(imp: speaker.id, client: client)
        guard case .ready(let url) = file.state, !Task.isCancelled else {
            StageVoice.shared.cancel(key: key)
            return
        }
        let made = clip ?? StageClip(url: url, kind: .audio, key: key, owner: speech.uuidString)
        clip = made
        if auto { StageVoice.shared.ready(key: key, owner: speech.uuidString) { [weak made] in made?.begin() ?? false } }
    }
}

/// The voice's only control: a puff of smoke in the Imp's colours, drifting and swelling with the
/// voice. Tap to pause, again to go on (or to hear it again).
struct StageOrb: View {
    var clip: StageClip?
    var hue: Double
    var failed = false
    var size: CGFloat = 34

    var body: some View {
        Button { clip?.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                let playing = clip?.isPlaying ?? false
                let level = clip?.level(at: t) ?? 0
                ZStack {
                    smoke(t: t, level: level, playing: playing)
                    Circle().fill(.white)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .blur(radius: size * 0.12)
                        .opacity(playing ? 0.25 + 0.5 * level : 0.15)
                    if failed || !playing {
                        Image(systemName: failed ? "exclamationmark" : clip == nil ? "waveform" : "play.fill")
                            .font(.system(size: size * 0.32, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2)
                            .offset(x: playing || failed || clip == nil ? 0 : size * 0.02)
                    }
                }
                .frame(width: size, height: size)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(clip == nil || failed)
        .accessibilityLabel(failed ? "Can't play" : (clip?.isPlaying ?? false) ? "Pause" : "Play")
    }

    private func smoke(t: Double, level: Double, playing: Bool) -> some View {
        let reach = size * (0.11 + 0.12 * level)
        let colors = Self.colors(hue)
        return ZStack {
            ForEach(0..<4, id: \.self) { i in
                let a = t * (0.8 + Double(i) * 0.27) + Double(i) * 1.7
                Circle()
                    .fill(RadialGradient(colors: [colors[i].opacity(0.95), colors[i].opacity(0.4), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.4))
                    .frame(width: size * 0.8, height: size * 0.8)
                    .offset(x: cos(a) * reach, y: sin(a * 1.3) * reach)
            }
        }
        .blur(radius: size * 0.065)
        .scaleEffect((playing ? 1 : 0.9) * (1 + 0.22 * level) * (1 + 0.035 * sin(t * 2.4)))
        .opacity(clip == nil ? 0.5 : 1)
    }

    private static func colors(_ hue: Double) -> [Color] {
        [(-1.0, 0.82, 0.95), (-0.35, 0.6, 1.0), (0.4, 0.78, 1.0), (1.0, 0.5, 1.0)]
            .map { Palette.RGB(h: hue + $0.0 * 0.08, s: $0.1, b: $0.2).color }
    }
}

/// A video in a bubble: a small player that takes its turn like a voice.
struct BubbleVideo: View {
    var ref: String
    var title: String
    var auto: Bool
    var speech: UUID
    var speaker: LinkImp
    var client: LinkClient

    init(ref: String, title: String, auto: Bool, speech: UUID, speaker: LinkImp, client: LinkClient) {
        self.ref = ref; self.title = title; self.auto = auto; self.speech = speech; self.speaker = speaker; self.client = client
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var clip: StageClip?

    var body: some View {
        Group {
            if let clip {
                VideoPlayer(player: clip.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(title.isEmpty ? String(localized: "Video") : title)
            } else if case .failed = file.state {
                Label(title.isEmpty ? String(localized: "Video") : title, systemImage: "film")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(Dungeon.muted)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
                    .aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
                    .overlay { ProgressView().tint(Dungeon.ember) }
            }
        }
        .task(id: ref) { await load() }
        .onDisappear { clip?.leave() }
    }

    private func load() async {
        let key = StageVoice.key(speech: speech, ref: ref)
        await file.load(imp: speaker.id, client: client)
        guard case .ready(let url) = file.state, !Task.isCancelled else {
            StageVoice.shared.cancel(key: key)
            return
        }
        let made = clip ?? StageClip(url: url, kind: .video, key: key, owner: speech.uuidString)
        clip = made
        if auto { StageVoice.shared.ready(key: key, owner: speech.uuidString) { [weak made] in made?.begin() ?? false } }
    }
}

/// A picture in a bubble, small.
struct BubbleThumb: View {
    var ref: String
    var alt: String
    var imp: UUID
    var client: LinkClient

    init(ref: String, alt: String, imp: UUID, client: LinkClient) {
        self.ref = ref; self.alt = alt; self.imp = imp; self.client = client
        _file = State(initialValue: ReplyFile(ref: ref))
    }
    @State private var file: ReplyFile
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 110, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel(alt.isEmpty ? String(localized: "Picture") : alt)
            } else if case .failed = file.state {
                Label(alt.isEmpty ? String(localized: "Picture") : alt, systemImage: "photo")
                    .font(.system(.caption, design: .rounded)).foregroundStyle(Dungeon.muted)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25))
                    .frame(width: 80, height: 60)
                    .overlay { ProgressView().tint(Dungeon.ember) }
            }
        }
        .task(id: ref) { await load() }
    }

    private func load() async {
        await file.load(imp: imp, client: client)
        guard case .ready(let url) = file.state else { return }
        if url.isFileURL {
            image = await Task.detached { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
        }
    }
}
