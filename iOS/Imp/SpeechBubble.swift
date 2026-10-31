import ImpKit
import SwiftUI

/// An Imp talking with another Imp, above its head: who (a chip in the other Imp's colour), the
/// question, and the answer when it comes. The same talk the Mac shows in the Imp's bubble; it
/// stays out of your chat. An answer with sound is the Imp *speaking*: the bubble's rim glows in the
/// speaker's colours and swells with the voice, and a small orb (tap it to pause or play) follows
/// the loudness. Pictures show as thumbnails, videos as a small player.
struct SpeechBubble: View {
    var speech: LinkSpeech
    /// The Imp saying it: its colours glow around a spoken reply, and its folder holds the files.
    var speaker: LinkImp
    var client: LinkClient
    /// A pocket Imp has no folder on the Mac: only what's on the web can load.
    var isPocket = false
    /// Where the tail points, from the bubble's middle (points).
    var tailOffset: CGFloat = 0
    var onDismiss: () -> Void

    /// The reply's blocks, without the files this phone can't get.
    private var blocks: [MarkdownBlock] {
        guard speech.role == .reply else { return [] }
        return SpeechBlocks.parse(speech.text).filter { block in
            switch block {
            case .image(let url, _, _), .media(let url, _, _, _): !isPocket || LinkFiles.isWeb(url.absoluteString)
            default: true
            }
        }
    }

    var body: some View {
        let blocks = blocks
        let speaks = !Markdown.voices(blocks).isEmpty
        let media = blocks.contains { SpeechBlocks.kind(of: $0) == .media }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color.imp(speech.hue)).frame(width: 9, height: 9)
                Text(header)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.imp(speech.hue)).brightness(0.18)
            }
            if speech.role == .reply {
                Text("“\(speech.question)”")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in row(block) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: media ? 210 : 150)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(speech.question)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Dungeon.cream)
                    .lineLimit(5)
                Dots().padding(.top, 1)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(width: 250, alignment: .leading)
        .background {
            BubbleShape(tail: tailOffset)
                .fill(Dungeon.deep.opacity(0.94))
                .overlay {
                    if speaks {
                        VoiceRim(hue: speaker.hue, owner: speech.id.uuidString, tail: tailOffset)
                    } else {
                        BubbleShape(tail: tailOffset).stroke(Color.imp(speech.hue).opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: media ? .contain : .combine)
        .accessibilityHint("Double-tap to dismiss.")
    }

    /// One block of a reply, compact.
    @ViewBuilder private func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            text(s)
        case .heading(_, let s):
            text(s).fontWeight(.bold)
        case .listItem(let marker, let depth, let s):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker ?? "").foregroundStyle(Dungeon.ember)
                text(s)
            }
            .font(.system(.subheadline, design: .rounded))
            .padding(.leading, CGFloat(depth) * 10)
        case .quote(let s):
            text(s).italic().foregroundStyle(Dungeon.muted)
        case .code(let code):
            Text(code).font(.system(.caption, design: .monospaced)).foregroundStyle(Dungeon.cream).lineLimit(8)
        case .table(let table):
            Text(([table.header] + table.rows).map { $0.map { String($0.characters) }.joined(separator: "  ·  ") }.joined(separator: "\n"))
                .font(.system(.caption, design: .rounded)).foregroundStyle(Dungeon.muted)
        case .rule:
            Rectangle().fill(Dungeon.cardEdge).frame(height: 1)
        case .image(let url, let alt, _):
            BubbleThumb(ref: url.absoluteString, alt: alt, imp: speaker.id, client: client)
        case .media(let url, let title, let kind, let auto):
            if kind == .audio {
                BubbleVoice(ref: url.absoluteString, title: title, auto: auto, speech: speech.id, speaker: speaker, client: client)
            } else {
                BubbleVideo(ref: url.absoluteString, title: title, auto: auto, speech: speech.id, speaker: speaker, client: client)
            }
        }
    }

    private func text(_ s: AttributedString) -> some View {
        Text(s)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(Dungeon.cream)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: String {
        switch speech.role {
        case .asked: String(localized: "\(speech.peer) asks")
        case .reply: String(localized: "Reply to \(speech.peer)")
        case .asking: String(localized: "Asking \(speech.peer)…")
        }
    }

    private struct Dots: View {
        var body: some View {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(Dungeon.flame).frame(width: 5, height: 5)
                            .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                    }
                }
            }
        }
    }
}

/// The bubble's edge while its Imp speaks: a soft band of the Imp's colours that drift around it
/// and swell with the voice, faint while the voice rests (the Mac's look, `VoiceAura`).
private struct VoiceRim: View {
    var hue: Double
    var owner: String
    var tail: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            let voice = StageVoice.shared.level(owner: owner, at: t)
            let presence = voice.playing ? 0.5 + 0.5 * voice.level : 0.22
            let colors = AngularGradient(colors: Self.colors(hue), center: .center, angle: .degrees(t * 0.07 * 360))
            let shape = BubbleShape(tail: tail)
            ZStack {
                shape.stroke(colors, style: StrokeStyle(lineWidth: 2 * (1 + 1.5 * voice.level), lineJoin: .round))
                    .blur(radius: 9 * (0.45 + 0.8 * voice.level))
                    .opacity(presence)
                shape.stroke(colors, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    .opacity(0.35 + 0.55 * presence)
            }
            .animation(.easeOut(duration: 0.4), value: voice.playing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Four shades around the Imp's hue (the first closes the loop, so there's no seam).
    static func colors(_ hue: Double) -> [Color] {
        let shades = [(-1.0, 0.82, 0.95), (-0.35, 0.6, 1.0), (0.4, 0.78, 1.0), (1.0, 0.5, 1.0)]
            .map { Palette.RGB(h: hue + $0.0 * 0.08, s: $0.1, b: $0.2).color }
        return shades + [shades[0]]
    }
}

/// A reply's Markdown parsed once, not on every frame the stage draws.
@MainActor
enum SpeechBlocks {
    enum Kind { case text, media }
    private static var cache: [String: [MarkdownBlock]] = [:]

    static func parse(_ text: String) -> [MarkdownBlock] {
        if let blocks = cache[text] { return blocks }
        if cache.count > 12 { cache.removeAll() }
        let blocks = Markdown.blocks(text)
        cache[text] = blocks
        return blocks
    }

    static func kind(of block: MarkdownBlock) -> Kind {
        switch block {
        case .image, .media: .media
        default: .text
        }
    }
}

/// A rounded bubble with a tail at the bottom, `tail` points from the middle, drawn as one outline
/// (so the border runs around the tail too, with no seam across its base). Held back from the
/// corners, the tail leans the rest of the way toward whatever it points at.
struct BubbleShape: Shape {
    var tail: CGFloat
    var radius: CGFloat = 16
    /// Half the tail's base, and how far it reaches below the bubble.
    var halfBase: CGFloat = 11
    var length: CGFloat = 12

    var animatableData: CGFloat {
        get { tail }
        set { tail = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let margin = r + halfBase + 2
        let wanted = rect.midX + tail
        // The base stays on the straight edge; the tip leans toward where it should point.
        let x = rect.width > 2 * margin ? min(max(wanted, rect.minX + margin), rect.maxX - margin) : rect.midX
        let lean = min(max(wanted - x, -halfBase * 0.9), halfBase * 0.9)
        let tip = CGPoint(x: x + lean, y: rect.maxY + length)
        let w = halfBase, bottom = rect.maxY

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX - r, y: bottom), radius: r)
        // The tail: it curves out of the edge and narrows to a soft point, and back.
        p.addLine(to: CGPoint(x: x + w, y: bottom))
        // Leaning, both sides sweep the same way (so neither folds back over the other).
        let sweep = lean * 0.65
        p.addCurve(to: tip,
                   control1: CGPoint(x: x + w * 0.3 + sweep, y: bottom),
                   control2: CGPoint(x: tip.x + w * 0.12, y: bottom + length * 0.5))
        p.addCurve(to: CGPoint(x: x - w, y: bottom),
                   control1: CGPoint(x: tip.x - w * 0.12, y: bottom + length * 0.5),
                   control2: CGPoint(x: x - w * 0.3 + sweep, y: bottom))
        p.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Inline Markdown (bold, italics, code, links) for short texts.
enum Inline {
    static func text(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}
