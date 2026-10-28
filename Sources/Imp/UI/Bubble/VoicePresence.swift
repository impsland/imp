import ImpKit
import SwiftUI

/// An answer with audio, in the speech bubble: instead of players, the Imp is seen speaking. The
/// card's edge glows in the Imp's colours, which drift around it and swell with the voice
/// (`VoiceAura`), and a puff of smoke breathes with it (`VoiceOrb`). Both follow the loudness of
/// what plays, measured from the file. The chat keeps its players.
enum VoiceReply {
    /// How this bubble presents its audio: nil when it shows as players (or has none).
    static func style(_ bubble: Bubble, prefs: ImpPreferences) -> VoiceStyle? {
        guard bubble.phase == .result, prefs.voiceStyle.speaks, bubble.text.contains("](") else { return nil }
        return Markdown.voices(Markdown.blocks(bubble.text)).isEmpty ? nil : prefs.voiceStyle
    }
}

/// The colours and motion of a speaking Imp, from its hue: every knob for the look in one place.
struct VoiceLook {
    var hue: Double
    /// How far the colours fan out from the Imp's own hue, either way (0…0.5 of the wheel).
    var spread = 0.08
    /// How fast the colours travel around the edge (turns a second).
    var drift = 0.07
    /// The glowing edge: its width and how far its light reaches, at rest and at the loudest.
    var rim: CGFloat = 2
    var glow: CGFloat = 9
    /// How much louder makes bigger (0: the voice doesn't move it).
    var response = 1.0

    /// Four shades around the Imp's hue: deeper and lighter, warmer and cooler. The first one
    /// closes the loop, so a gradient around a shape has no seam.
    var colors: [Color] {
        let shades = [(-1.0, 0.82, 0.95), (-0.35, 0.6, 1.0), (0.4, 0.78, 1.0), (1.0, 0.5, 1.0)]
            .map { Palette.RGB(h: hue + $0.0 * spread, s: $0.1, b: $0.2).color }
        return shades + [shades[0]]
    }
}

/// What the voice is doing right now, read every frame.
struct VoiceNow {
    var media: Media?
    var playing: Bool
    /// 0…1, how loud.
    var level: Double

    /// Reading the bubble's look from a still picture (measuring, design renders): mid-sentence.
    static let still = VoiceNow(media: nil, playing: true, level: 0.55)
}

/// A clock for the voice: 30 frames a second while the bubble shows, so it picks up its audio as
/// soon as that loads and follows every syllable. Still while measuring.
struct VoiceClock<Content: View>: View {
    let owner: String
    var measuring = false
    /// Drawn as if the voice were doing this, at a moment `t` (design renders).
    var preview: (t: Double, now: VoiceNow)?
    @ViewBuilder var content: (_ t: Double, _ now: VoiceNow) -> Content

    var body: some View {
        if let preview {
            content(preview.t, preview.now)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: measuring)) { context in
                let t = measuring ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
                content(t, measuring ? .still : Self.now(owner, t))
            }
        }
    }

    private static func now(_ owner: String, _ t: Double) -> VoiceNow {
        let media = Playback.shared.voice(owner: owner)
        let playing = media?.isPlaying ?? false
        return VoiceNow(media: media, playing: playing, level: media?.level(at: t) ?? 0)
    }
}

/// The card's edge, alive: a soft band of the Imp's colours that drift around it, breathing out
/// with each word. Faint while the voice rests; gone into the glass once it's quiet.
struct VoiceAura: View {
    let look: VoiceLook
    let owner: String
    var cornerRadius: CGFloat = 20
    var measuring = false
    var preview: (t: Double, now: VoiceNow)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VoiceClock(owner: owner, measuring: measuring, preview: preview) { t, now in
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let level = now.level * look.response
            let presence = now.playing ? 0.5 + 0.5 * level : 0.22
            let colors = AngularGradient(colors: look.colors, center: .center,
                                         angle: .degrees(t * look.drift * 360))
            ZStack {
                // A wash from the edges, behind the text (it stays easy to read).
                shape.strokeBorder(colors, lineWidth: 18)
                    .blur(radius: 16)
                    .opacity((scheme == .dark ? 0.22 : 0.14) * presence)
                    .clipShape(shape)
                // The light around it, reaching out with the voice.
                shape.strokeBorder(colors, lineWidth: look.rim * (1 + 1.5 * level))
                    .blur(radius: look.glow * (0.45 + 0.8 * level))
                    .opacity(presence)
                // The edge itself.
                shape.strokeBorder(colors, lineWidth: 1.1)
                    .opacity(0.35 + 0.55 * presence)
            }
            .animation(.easeOut(duration: 0.4), value: now.playing)     // stopping fades, it doesn't snap
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A puff of smoke in the Imp's colours: soft blobs that drift around each other and swell with
/// the voice. It's the voice's only control: click to pause, again to go on (or hear it again).
struct VoiceOrb: View {
    let look: VoiceLook
    let owner: String
    var size: CGFloat = 28
    var measuring = false
    var preview: (t: Double, now: VoiceNow)?
    @State private var hover = false

    var body: some View {
        VoiceClock(owner: owner, measuring: measuring, preview: preview) { t, now in
            let level = now.level * look.response
            let failed = now.media?.failed ?? false
            Button { now.media?.toggle() } label: {
                ZStack {
                    halo(level: level, playing: now.playing)
                    smoke(t: t, level: level, playing: now.playing)
                    // The bright heart of it, flaring on louder sounds.
                    Circle().fill(.white)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .blur(radius: size * 0.12)
                        .opacity(now.playing ? 0.25 + 0.5 * level : 0.15)
                    if hover || !now.playing {
                        Image(systemName: failed ? "exclamationmark" : now.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: max(size * 0.32, 9), weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2)
                            .offset(x: now.playing || failed ? 0 : size * 0.02)
                            .transition(.opacity)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(now.media == nil || failed)
            .help(failed ? "Can't play this" : now.playing ? "Pause" : "Play")
            .accessibilityLabel(failed ? "Can't play" : now.playing ? "Pause" : "Play")
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    private func halo(level: Double, playing: Bool) -> some View {
        Circle()
            .fill(RadialGradient(colors: [look.colors[1].opacity(0.55), .clear], center: .center,
                                 startRadius: 0, endRadius: size * 0.62))
            .frame(width: size * 1.25, height: size * 1.25)
            .scaleEffect(1 + 0.2 * level)
            .opacity(playing ? 1 : 0.55)
    }

    private func smoke(t: Double, level: Double, playing: Bool) -> some View {
        let reach = size * (0.11 + 0.12 * level)
        let colors = look.colors
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
    }
}
