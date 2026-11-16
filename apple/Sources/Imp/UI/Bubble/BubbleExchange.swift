import ImpKit
import SwiftUI
import ImpDesign

/// How two Imps talking to each other read, in the bubble and in the chat. Whoever's words these
/// are, a small chip in that Imp's colour says what's going on ("Pip asks", "Reply to Pip",
/// "Asking Mo…"), and a reply is plain body text. The question is quoted once: by the Imp that
/// asks it ("Asking Mo…"), not again by the Imp that is asked.
struct ExchangeChip: View {
    let role: Bubble.Exchange.Role
    let peer: ChatTurn.Sender

    var body: some View {
        let colour = Color.imp(peer.hue)
        HStack(spacing: Spacing.snug) {
            Circle().fill(colour).frame(width: BubbleMetrics.dot, height: BubbleMetrics.dot)
            Self.words(role, peer.name)
                .font(Typeface.small)
                .lineLimit(1)
        }
        .foregroundStyle(Tone.text)
        .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.tight)
        .background(Capsule().fill(colour.opacity(Opacity.tintFill)))
        .fixedSize()
    }

    /// The name in bold, the rest plain.
    static func words(_ role: Bubble.Exchange.Role, _ peerName: String) -> Text {
        let name = Text(peerName).fontWeight(.semibold)
        switch role {
        case .asked: return Text("\(name) asks")
        case .reply: return Text("Reply to \(name)")
        case .asking: return Text("Asking \(name)…")
        case .answered: return Text(String(format: String(localized: "exchange.answered"), peerName))
        }
    }
}

/// The chip and, for the Imp doing the asking, its question quoted with a bar in its own colour.
/// The Imp being asked shows only the chip, so the question isn't on screen twice.
struct ExchangeHeader: View {
    @Environment(\.impTint) private var tint
    let exchange: Bubble.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            ExchangeChip(role: exchange.role, peer: exchange.peer)
            if exchange.role == .asking, !exchange.question.isEmpty {
                Text(exchange.question)
                    .font(Typeface.body)
                    .foregroundStyle(Tone.muted)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Spacing.cozy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: BubbleMetrics.bar)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
