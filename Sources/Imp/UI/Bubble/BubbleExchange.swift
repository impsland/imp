import ImpKit
import SwiftUI

/// How two Imps talking to each other read, in the bubble and in the chat. Whoever's words these
/// are, a small chip in that Imp's colour says what's going on ("Pip asks", "Reply to Pip",
/// "Asking Mo…"), the question is quoted under it with a bar, and a reply is plain body text.
struct ExchangeChip: View {
    let role: Bubble.Exchange.Role
    let peer: ChatTurn.Sender

    var body: some View {
        let colour = Color.imp(peer.hue)
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Self.words(role, peer.name)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.8))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(colour.opacity(0.2)))
        .overlay(Capsule().strokeBorder(colour.opacity(0.45), lineWidth: 0.5))
        .fixedSize()
    }

    /// The name in bold, the rest plain.
    static func words(_ role: Bubble.Exchange.Role, _ name: String) -> Text {
        let name = Text(name).fontWeight(.semibold)
        switch role {
        case .asked: return name + Text(" asks")
        case .reply: return Text("Reply to ") + name
        case .asking: return Text("Asking ") + name + Text("…")
        }
    }
}

/// The chip and, for a question, the question quoted: its bar is the colour of whoever asked
/// (the other Imp when it asks, this one when it does the asking).
struct ExchangeHeader: View {
    @Environment(\.impTint) private var tint
    let exchange: Bubble.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExchangeChip(role: exchange.role, peer: exchange.peer)
            if exchange.role != .reply, !exchange.question.isEmpty {
                Text(exchange.question)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Capsule().fill(exchange.role == .asked ? Color.imp(exchange.peer.hue) : tint).frame(width: 3)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
