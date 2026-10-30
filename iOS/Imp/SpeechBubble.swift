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
                .overlay(BubbleShape(tail: tailOffset).stroke(Color.imp(speech.hue).opacity(0.55), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round)))
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
