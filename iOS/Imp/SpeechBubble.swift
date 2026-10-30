import ImpKit
import SwiftUI

/// An Imp talking with another Imp, above its head: who (a chip in the other Imp's colour), the
/// question, and the answer when it comes. The same talk the Mac shows in the Imp's bubble; it
/// stays out of your chat.
struct SpeechBubble: View {
    var speech: LinkSpeech
    /// Where the tail points, from the bubble's middle (points).
    var tailOffset: CGFloat = 0
    var onDismiss: () -> Void

    var body: some View {
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
                    Text(Inline.text(speech.text))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Dungeon.cream)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 150)
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
                .overlay(BubbleShape(tail: tailOffset).stroke(Color.imp(speech.hue).opacity(0.55), lineWidth: 1.2))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to dismiss.")
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

/// A rounded bubble with a little tail at the bottom, `tail` points from the middle.
struct BubbleShape: Shape {
    var tail: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
        let x = min(max(rect.midX + tail, rect.minX + 22), rect.maxX - 22)
        p.move(to: CGPoint(x: x - 9, y: rect.maxY - 0.5))
        p.addQuadCurve(to: CGPoint(x: x, y: rect.maxY + 10), control: CGPoint(x: x - 2, y: rect.maxY + 4))
        p.addQuadCurve(to: CGPoint(x: x + 9, y: rect.maxY - 0.5), control: CGPoint(x: x + 2, y: rect.maxY + 4))
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
