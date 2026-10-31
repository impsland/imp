import ImpKit
import SwiftUI

/// Which talk to open: what one Imp and another said to each other.
struct TalkRequest: Identifiable, Equatable {
    let imp: UUID
    let peer: UUID
    var id: String { "\(imp)-\(peer)" }
}

/// A talk between two Imps, read-only, on the Home window: opened from the bubble chat's menu
/// and from the Imp's Memory in Settings. It collects both Imps' halves of the conversation.
struct TalkSheet: View {
    let model: AppModel
    let request: TalkRequest
    @Environment(\.dismiss) private var dismiss
    @State private var thread: TalkThread?
    @State private var loaded = false

    private var me: ChatTurn.Sender? {
        model.profile(request.imp).map { ChatTurn.Sender(id: $0.id, name: $0.name, hue: $0.hue) }
    }

    var body: some View {
        let peer = thread?.peer
        SheetScaffold(icon: "person.2.fill", title: peer.map { "Talk with \($0.name)" } ?? "Talk",
                      info: "What \(me?.name ?? "this Imp") and \(peer?.name ?? "another Imp") said to each other, both ways. This is only to read: it comes from both Imps' chats.",
                      width: 560) {
            if let me, let thread {
                ScrollViewReader { reader in
                    TalkThreadView(thread: thread, me: me)
                        .onAppear { reader.scrollTo(thread.lines.last?.id, anchor: .bottom) }
                }
            } else if loaded {
                StatusText(text: "Nothing said between them yet.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        } footer: {
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .task {
            let lines = await model.talkLines()
            thread = TalkLog.threads(of: request.imp, from: lines).first { $0.peer.id == request.peer }
            loaded = true
        }
    }
}

/// The lines of a talk like a messenger: this Imp's words on the right, the other's on the left,
/// each in its own colour, a day heading when the day changes. Replies are Markdown, so pictures
/// and voices work.
struct TalkThreadView: View {
    let thread: TalkThread
    /// The Imp whose talk this is.
    let me: ChatTurn.Sender

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(thread.lines.enumerated()), id: \.element.id) { index, line in
                if index == 0 || !Calendar.current.isDate(line.date, inSameDayAs: thread.lines[index - 1].date) {
                    Text(line.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Dungeon.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, index == 0 ? 0 : 6)
                }
                TalkLineView(line: line, me: me).id(line.id)
            }
        }
        .textSelection(.enabled)
    }
}

/// One exchange: the question from whoever asked, then the answer.
private struct TalkLineView: View {
    let line: TalkLine
    let me: ChatTurn.Sender

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            side(of: line.asker) {
                ExchangeChip(role: .asked, peer: line.asker)
                Text(line.question).font(.system(size: 13))
            }
            side(of: line.answerer) {
                ExchangeChip(role: .reply, peer: line.asker)
                if line.failed {
                    Label(line.reply, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                } else {
                    MarkdownView(blocks: Markdown.blocks(line.reply), base: Workspace.directory(for: line.answerer.id), fontSize: 13,
                                 mediaOwner: line.id.uuidString)
                }
            }
        }
    }

    /// A card in the speaker's colour: this Imp's to the right, the other's to the left.
    private func side<Content: View>(of speaker: ChatTurn.Sender, @ViewBuilder _ content: () -> Content) -> some View {
        let mine = speaker.id == me.id
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.imp(speaker.hue).opacity(0.16)))
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: 56) }
        }
    }
}
