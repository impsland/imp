import ImpDesign
import ImpKit
import SwiftUI

/// Which talk to open: what one Imp and another said to each other.
struct TalkRequest: Identifiable, Equatable {
    let imp: UUID
    let peer: UUID
    /// A chat with you to read instead (`peer` is then unused).
    var chat: UUID?
    var id: String { "\(imp)-\(peer)-\(chat?.uuidString ?? "")" }
}

/// How a conversation is shown: as bubbles, or as the JSON of the same messages.
enum ConversationMode: Hashable { case chat, json }

/// A conversation, read-only, on the Home window: a talk between two Imps (opened from the bubble
/// chat's menu and from Settings) or a chat with you. It shows as bubbles or as JSON made from the
/// same messages, and the JSON can be copied.
struct TalkSheet: View {
    let model: AppModel
    let request: TalkRequest
    @State private var thread: TalkThread?
    @State private var chat: Chat?
    @State private var loaded = false
    @State private var mode = ConversationMode.chat
    @State private var copied = false

    private var me: ChatTurn.Sender? {
        model.profile(request.imp).map { ChatTurn.Sender(id: $0.id, name: $0.name, hue: $0.hue) }
    }

    /// The JSON of exactly what the bubbles show.
    private var json: String {
        if request.chat != nil { return Transcript.json(chat?.turns ?? []) }
        return Transcript.json(thread?.lines ?? [])
    }

    private var isEmpty: Bool { request.chat != nil ? (chat?.turns.isEmpty ?? true) : (thread?.lines.isEmpty ?? true) }

    var body: some View {
        let peer = thread?.peer
        SheetScaffold(icon: request.chat != nil ? "bubble.left.and.bubble.right.fill" : "person.2.fill",
                      title: request.chat != nil ? LocalizedStringKey(chat?.title.isEmpty == false ? chat!.title : "Chat")
                          : LocalizedStringKey(peer.map { "Talk with \($0.name)" } ?? "Talk"),
                      info: request.chat != nil
                          ? "What you and \(me?.name ?? "this Imp") said in this chat. This is only to read. Show it as bubbles or as JSON, and copy the JSON."
                          : "What \(me?.name ?? "this Imp") and \(peer?.name ?? "another Imp") said to each other, both ways. This is only to read: it comes from both Imps' chats. Show it as bubbles or as JSON, and copy the JSON.",
                      width: Sizing.sheetWidth, accessory: {
            ImpSegmented("View as", selection: $mode, options: [ConversationMode.chat, .json],
                         title: { $0 == .chat ? String(localized: "Chat") : String(localized: "JSON") },
                         symbol: { $0 == .chat ? "bubble.left.and.bubble.right" : "curlybraces" })
        }, content: {
            if loaded, isEmpty {
                StatusText(text: "Nothing said yet.")
            } else if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, Spacing.page)
            } else if mode == .json {
                Text(verbatim: json)
                    .font(Typeface.mono).foregroundStyle(Tone.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let me, let thread {
                ScrollViewReader { reader in
                    TalkThreadView(thread: thread, me: me)
                        .onAppear { reader.scrollTo(thread.lines.last?.id, anchor: .bottom) }
                }
            } else if let me, let chat {
                ScrollViewReader { reader in
                    ChatTurnsView(turns: chat.turns, me: me)
                        .onAppear { reader.scrollTo(chat.turns.last?.id, anchor: .bottom) }
                }
            }
        }, footer: {
            if mode == .json, !isEmpty {
                Button(copied ? "Copied" : "Copy JSON") {
                    Pasteboard.write(text: json)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                .buttonStyle(.quiet)
            }
        })
        .task {
            if let id = request.chat {
                chat = await model.chat(id, of: request.imp)
            } else {
                let lines = await model.talkLines()
                thread = TalkLog.threads(of: request.imp, from: lines).first { $0.peer.id == request.peer }
            }
            loaded = true
        }
    }
}

/// Sizes of a conversation that no token covers.
private enum TalkMetrics {
    /// The point size markdown replies are read at: the body text size, which `MarkdownView` takes as a number.
    static let readingSize: CGFloat = 13
    /// The empty gutter on the side a bubble does not use.
    static let gutter = Sizing.hit * 2
}

/// The turns of a chat with you like a messenger: your words on the right, the Imp's reply on the left.
struct ChatTurnsView: View {
    fileprivate static let readingSize = TalkMetrics.readingSize
    fileprivate static let gutter = TalkMetrics.gutter
    let turns: [ChatTurn]
    /// The Imp whose chat this is.
    let me: ChatTurn.Sender

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                if index == 0 || !Calendar.current.isDate(turn.date, inSameDayAs: turns[index - 1].date) {
                    Text(turn.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(Typeface.small).foregroundStyle(Tone.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, index == 0 ? 0 : Spacing.snug)
                }
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    if turn.via != .recap {
                        card(tint: Tone.card, mine: true) {
                            Text(turn.sender.map { "\($0.name): \(turn.request)" } ?? turn.request).font(Typeface.body)
                        }
                    }
                    card(tint: Color.imp(me.hue).opacity(Opacity.tintFill), mine: false) {
                        if turn.failed {
                            Label(turn.reply, systemImage: "exclamationmark.triangle.fill")
                                .font(Typeface.body).foregroundStyle(Tone.danger)
                        } else {
                            // Pictures load (a view without `onImageLoad` is only being measured, and loads nothing):
                            // the sheet scrolls, so it simply grows as they arrive.
                            MarkdownView(blocks: Markdown.blocks(turn.reply), base: Workspace.directory(for: me.id), fontSize: Self.readingSize,
                                         onImageLoad: {}, mediaOwner: turn.id.uuidString)
                        }
                    }
                }
                .id(turn.id)
            }
        }
        .textSelection(.enabled)
    }

    private func card<Content: View>(tint: Color, mine: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: Self.gutter) }
            VStack(alignment: .leading, spacing: Spacing.snug) { content() }
                .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(tint))
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: Self.gutter) }
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
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(Array(thread.lines.enumerated()), id: \.element.id) { index, line in
                if index == 0 || !Calendar.current.isDate(line.date, inSameDayAs: thread.lines[index - 1].date) {
                    Text(line.date, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(Typeface.small).foregroundStyle(Tone.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, index == 0 ? 0 : Spacing.snug)
                }
                TalkLineView(line: line, me: me).id(line.id)
            }
        }
        .textSelection(.enabled)
    }
}

/// One exchange: the question from whoever asked, then the answer.
private struct TalkLineView: View {
    fileprivate static let readingSize = TalkMetrics.readingSize
    fileprivate static let gutter = TalkMetrics.gutter
    let line: TalkLine
    let me: ChatTurn.Sender

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            side(of: line.asker) {
                ExchangeChip(role: .asked, peer: line.asker)
                Text(line.question).font(Typeface.body)
            }
            side(of: line.answerer) {
                ExchangeChip(role: .reply, peer: line.asker)
                if line.failed {
                    Label(line.reply, systemImage: "exclamationmark.triangle.fill")
                        .font(Typeface.body).foregroundStyle(Tone.danger)
                } else {
                    // A file named in the answer is in the folder of the Imp that answered. Pictures load (see `ChatTurnsView`).
                    MarkdownView(blocks: Markdown.blocks(line.reply), base: Workspace.directory(for: line.answerer.id), fontSize: Self.readingSize,
                                 onImageLoad: {}, mediaOwner: line.id.uuidString)
                }
            }
        }
    }

    /// A card in the speaker's colour: this Imp's to the right, the other's to the left.
    private func side<Content: View>(of speaker: ChatTurn.Sender, @ViewBuilder _ content: () -> Content) -> some View {
        let mine = TalkSide(speaker: speaker.id, owner: me.id) == .mine
        return HStack(spacing: 0) {
            if mine { Spacer(minLength: Self.gutter) }
            VStack(alignment: .leading, spacing: Spacing.snug) { content() }
                .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Color.imp(speaker.hue).opacity(Opacity.tintFill)))
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: Self.gutter) }
        }
    }
}
