import ImpDesign
import ImpKit
import SwiftUI

/// The chat: everything you and this Imp said (each request, the tools it used, open one to see
/// its request and response, and the reply), newest at the bottom, with a text box to keep
/// talking. What you send here is answered here, streaming in as the newest turn. Older turns
/// load a page at a time. The header switches between saved chats, starts a new one, and recaps
/// a long one.
struct ChatView: View {
    @Environment(\.impTint) private var tint
    let model: ImpModel
    let bubble: Bubble
    let layout: BubbleLayout
    @State private var moving = false
    var measuring = false
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Turns shown at first, and added by each page of earlier ones.
    static let page = 25
    /// The least height the transcript keeps, however much the text box grows.
    static let minTranscript: CGFloat = 80

    var body: some View {
        let history = model.history
        let live = model.chatWork
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            header
            if let reason = model.sleepReason {
                Label("\(model.profile.name) is asleep. \(reason)", systemImage: "moon.zzz.fill")
                    .font(Typeface.body).foregroundStyle(Tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.recapError {
                Label("Couldn't recap: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.body).foregroundStyle(Tone.danger)
                    .lineLimit(2)
            }
            if model.showsContextNotice {
                ContextNotice(model: model, changed: changed)
            }
            if history.turns.isEmpty && live == nil {
                Text("A new chat. Ask \(model.profile.name) anything.")
                    .font(Typeface.body).foregroundStyle(Tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                let shown = Array(history.latest(layout.chatPages * Self.page))
                let earlier = history.turns.count - shown.count
                // Turns above the latest recap are still here to read, but the model only has the recap.
                let recapped = shown.lastIndex { $0.via == .recap }
                ScrollViewReader { reader in
                    ScrollView {
                        // Not lazy: a lazy stack only guesses the height of the turns it hasn't drawn, so the chat opened
                        // scrolled past its end, blank until scrolled up. The pages keep it small: thousands of turns are
                        // never laid out at once, a page at a time, the next one loading as you scroll up to the top (or
                        // with a click).
                        VStack(alignment: .leading, spacing: Spacing.large) {
                            if earlier > 0 {
                                EarlierTurns(count: earlier, measuring: measuring) {
                                    showEarlier(from: shown.first?.id, reader)
                                }
                                .id(layout.chatPages)        // A new id for each page, so the loader fires again for the next one
                            }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, turn in
                                if turn.via == .recap {
                                    RecapCard(turn: turn, model: model, layout: layout, measuring: measuring)
                                } else {
                                    TurnView(turn: turn, steps: turn.steps.map(Bubble.Step.init), live: false,
                                             model: model, layout: layout, measuring: measuring)
                                        .opacity(recapped.map { index < $0 } == true ? Opacity.dimmed : 1)
                                }
                            }
                            // The request being worked on, live: its tools as they run, the answer as it streams.
                            if let live {
                                TurnView(turn: { var t = live.ask; t.reply = live.text; return t }(), steps: live.steps, live: true,
                                         model: model, layout: layout, measuring: measuring)
                            }
                            Color.clear.frame(height: BubbleMetrics.anchor).id(Self.end)
                        }
                        // Only a little room at the bottom. The sides get none, since the scroll bar
                        // brings its own gutter when it shows.
                        .padding(.bottom, Spacing.tight)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(minHeight: Self.minTranscript, maxHeight: .infinity)
                    // Keep the newest words in view as you send and as the answer streams in.
                    .onChange(of: history.turns.count) { _, _ in follow(reader) }
                    .onChange(of: live?.ask.date) { _, _ in follow(reader) }
                    .onChange(of: live?.text) { _, _ in follow(reader, animated: false) }
                    .onChange(of: live?.steps.count) { _, _ in follow(reader) }
                }
            }
            TypingField(model: model, bubble: bubble, measuring: measuring, chat: true)
        }
    }

    private static let end = "end"

    /// The next page of older turns, keeping the turn you were looking at where it was.
    private func showEarlier(from oldest: UUID?, _ reader: ScrollViewProxy) {
        guard !measuring else { return }
        layout.chatPages += 1
        guard let oldest else { return }
        Task { @MainActor in
            // Lets the new page lay out before scrolling back to the turn that was at the top.
            await Task.yield()
            reader.scrollTo(oldest, anchor: .top)
        }
    }

    private func follow(_ reader: ScrollViewProxy, animated: Bool = true) {
        guard !measuring else { return }
        if animated {
            withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { reader.scrollTo(Self.end, anchor: .bottom) }
        } else {
            reader.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// The chat you're in (a menu of the saved ones), then recap, new chat and delete.
    private var header: some View {
        HStack(spacing: Spacing.cozy) {
            // The move handle: drag the card by it, or by any part of the card that isn't text or a button.
            // It takes the drag itself, since it sits in front of the card and would otherwise swallow the mouse-down.
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(Typeface.small.weight(.semibold))
                .foregroundStyle(Tone.faint)
                .frame(width: Spacing.huge, height: Spacing.huge)
                .contentShape(Rectangle())
                .pointerStyle(moving ? .grabActive : .grabIdle)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in moving = true; layout.onDrag?(false) }
                    .onEnded { _ in moving = false; layout.onDrag?(true) })
                .help("Drag to move")
                .accessibilityLabel(Text("Drag to move"))
            // The title gives way (one line, cut at the end) so the buttons always keep their room.
            ChatPicker(model: model, changed: changed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            if model.isRecapping {
                HStack(spacing: Spacing.snug) {
                    ProgressView().controlSize(.mini)
                    Text("Recapping…").font(Typeface.small.weight(.medium)).foregroundStyle(Tone.muted)
                        .lineLimit(1).fixedSize()
                }
                .layoutPriority(2)
            } else if model.canRecap {
                ConfirmButton(icon: "rectangle.compress.vertical", confirm: "Recap?",
                              help: "Recap: \(model.profile.name) sums up this chat and remembers only that and the last message, so a long chat fits again") {
                    model.recapChat()
                }
                .fixedSize().layoutPriority(2)
            }
            if !model.history.isEmpty {
                ConfirmButton(icon: "plus.bubble", confirm: "New chat?", help: "New chat (this one stays in the list)") {
                    model.startNewChat()
                }
                .fixedSize().layoutPriority(2)
                if model.visit == nil { deleteButton.fixedSize().layoutPriority(2) }
            }
        }
        .frame(height: BubbleMetrics.button)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// The chat changed: start at its newest turns, and re-measure the bubble.
    private func changed() {
        layout.chatPages = 1
        confirmingDelete = false
        layout.onToggle?()
    }

    /// Two steps, since deleting cannot be undone: the trash button, then "Delete chat?" for three seconds.
    private var deleteButton: some View {
        Button {
            if confirmingDelete {
                model.deleteChat(model.history.current.id)
                changed()
            } else {
                confirmingDelete = true
                Task { try? await Task.sleep(for: .seconds(3)); confirmingDelete = false }
            }
        } label: {
            if confirmingDelete {
                Text("Delete chat?").font(Typeface.small.weight(.semibold)).foregroundStyle(Tone.danger)
                    .lineLimit(1).fixedSize()
            } else {
                Image(systemName: "trash").font(.icon(.medium, weight: .medium)).foregroundStyle(Tone.muted)
                    .frame(width: BubbleMetrics.button, height: BubbleMetrics.button).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Delete this chat and \(model.profile.name)'s memory of it.")
        .accessibilityLabel("Delete chat")
    }
}

/// What the talks list is read again for: another chat, or newer talk in the chats.
private struct TalksRefresh: Equatable {
    let chat: UUID
    let updated: Date?
}

/// The current chat's name, opening a list of every saved chat to switch to (and a new one).
private struct ChatPicker: View {
    let model: ImpModel
    let changed: () -> Void
    /// The talks this Imp had with other Imps, newest first, read from the app's talk log.
    @State private var talks: [TalkThread] = []

    var body: some View {
        let history = model.history
        Menu {
            // Chats with you. A conversation with another Imp is a talk (below), read, not carried on.
            let chats = history.chats.filter { $0.peer == nil }
            if !chats.isEmpty {
                Section("Chats") {
                    ForEach(chats.prefix(30)) { chat in
                        Toggle(isOn: Binding(get: { chat.id == history.current.id },
                                             set: { _ in model.switchChat(to: chat.id); changed() })) {
                            Text(chat.title.isEmpty ? String(localized: "Chat") : chat.title)
                            Text(chat.updated, format: .dateTime.day().month().hour().minute())
                        }
                        // A visiting Imp's chats are at its home: nothing to switch while it can't hear.
                        .disabled(model.visit?.isAwake == false)
                    }
                }
            }
            if !talks.isEmpty {
                Section("Talks") {
                    ForEach(talks.prefix(10)) { talk in
                        Button { HomeWindow.shared.showTalk(model.app, imp: model.id, peer: talk.peer.id) } label: {
                            Label(talk.peer.name, systemImage: "person.2")
                            Text(talk.updated, format: .dateTime.day().month().hour().minute())
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.tight) {
                if model.history.current.peer != nil { Image(systemName: "person.2.fill").font(.icon(.small, weight: .regular)) }
                Text(title).font(Typeface.label).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.muted).layoutPriority(1)
            }
            .foregroundStyle(Tone.text)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Your chats with \(model.profile.name). Pick one to carry on where you left off. Talks with other Imps open to read.")
        .task(id: TalksRefresh(chat: model.history.current.id, updated: model.history.chats.first?.updated)) {
            talks = TalkLog.threads(of: model.id, from: await model.app.talkLines())
        }
    }

    private var title: String {
        let t = model.history.current.title
        return t.isEmpty ? String(localized: "New chat with \(model.profile.name)") : t
    }
}

/// The top of the loaded turns, when there are older ones: they load as it scrolls into view
/// (or on a click), a page at a time.
private struct EarlierTurns: View {
    @Environment(\.impTint) private var tint
    let count: Int
    let measuring: Bool
    let load: () -> Void
    @State private var loaded = false
    @State private var inView = false

    var body: some View {
        Button { once() } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: "chevron.up").font(.icon(.small, weight: .bold))
                Text("\(count) earlier messages").font(Typeface.small.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(LegibleTint(on: .raised))
        .help("Show earlier messages")
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            // Scrolled up to the top: the next page comes in by itself. Only if it stays in view a moment (the
            // chat opens at the bottom, and may pass over it while it settles there).
            inView = visible
            guard visible, !measuring else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if inView { once() }
            }
        }
    }

    private func once() {
        guard !loaded else { return }
        loaded = true
        load()
    }
}

/// A small icon button in the chat's header that asks first: a click swaps the icon for its question
/// for three seconds, and a second click runs the action.
private struct ConfirmButton: View {
    let icon: String
    let confirm: LocalizedStringKey
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var asking = false
    @Environment(\.impTint) private var tint

    var body: some View {
        Button {
            if asking { asking = false; action() } else {
                asking = true
                Task { try? await Task.sleep(for: .seconds(3)); asking = false }
            }
        } label: {
            if asking {
                Text(confirm).font(Typeface.small.weight(.semibold)).foregroundStyle(LegibleTint(on: .raised))
                    .lineLimit(1).fixedSize()
            } else {
                Image(systemName: icon).font(.icon(.medium, weight: .medium)).foregroundStyle(Tone.muted)
                    .frame(width: BubbleMetrics.button, height: BubbleMetrics.button).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet suggestion, once per chat, when the chat has grown long enough to be slow and costly
/// (`ImpProfile.newChatAt`). It never blocks anything: recap, start a new chat, or wave it away.
private struct ContextNotice: View {
    let model: ImpModel
    let changed: () -> Void

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "text.badge.star").font(.icon(.medium, weight: .regular)).foregroundStyle(Tone.muted)
            Text("This chat is getting long. A recap or a new chat keeps \(model.profile.name) quick.")
                .font(Typeface.small).foregroundStyle(Tone.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.tight)
            if model.canRecap {
                Button("Recap") { model.dismissContextNotice(); model.recapChat() }
                    .buttonStyle(.imp(.secondary, small: true))
            }
            Button("New chat") { model.dismissContextNotice(); model.startNewChat(); changed() }
                .buttonStyle(.imp(.secondary, small: true))
            Button { model.dismissContextNotice(); changed() } label: {
                Image(systemName: "xmark").font(.icon(.small, weight: .semibold)).foregroundStyle(Tone.muted)
                    .frame(width: BubbleMetrics.corner, height: BubbleMetrics.corner).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.card))
    }
}

/// Where the chat was recapped: the recap the model keeps instead of the turns above it.
private struct RecapCard: View {
    @Environment(\.impTint) private var tint
    let turn: ChatTurn
    let model: ImpModel
    let layout: BubbleLayout
    let measuring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                Label("Recap", systemImage: "rectangle.compress.vertical").font(Typeface.small.weight(.semibold))
                Text(turn.date, format: .dateTime.day().month().hour().minute()).font(Typeface.small).foregroundStyle(Tone.muted)
                Spacer(minLength: 0)
                InfoTip("\(model.profile.name) remembers this recap instead of the messages above it.")
            }
            .foregroundStyle(LegibleTint(on: .raised))
            MarkdownView(blocks: model.replyBlocks(turn.reply), base: Workspace.directory(for: model.id), fontSize: 12,
                         onImageLoad: measuring ? nil : { layout.onToggle?() }, measuring: measuring)
                .foregroundStyle(Tone.muted)
        }
        .padding(Spacing.cozy)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(Tone.card))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One exchange: your request on the right, then the tools and the reply. The live one (in
/// progress) says "Now", and shows dots until the answer starts.
private struct TurnView: View {
    let turn: ChatTurn
    let steps: [Bubble.Step]
    let live: Bool
    let model: ImpModel
    let layout: BubbleLayout
    let measuring: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Group {
                if live { Text("Now") } else { Text(turn.date, format: .dateTime.day().month().hour().minute()) }
            }
            .font(Typeface.small).foregroundStyle(Tone.muted)
            .frame(maxWidth: .infinity)
            // Yours on the right. Another Imp's on the left, in its colour.
            HStack {
                if turn.via != .imp { Spacer(minLength: Sizing.hit * 2) }
                RequestCard(turn: turn, model: model, layout: layout, measuring: measuring)
                if turn.via == .imp { Spacer(minLength: Sizing.hit * 2) }
            }
            if !steps.isEmpty {
                StepList(steps: steps, layout: layout, animated: live && !measuring)
            }
            if live, let prompt = model.prompt { PermissionPromptView(prompt: prompt, answer: model.answerPermission) }
            if turn.failed {
                Label(turn.reply, systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.body).foregroundStyle(Tone.danger)
            } else if turn.reply.isEmpty {
                ThinkingDots(animated: live && !measuring)
            } else {
                // Only an answer that arrived while you had the chat open may start its media
                // (`#autoplay`), once: scrolling back through older ones never plays them.
                let fresh = !live && model.freshTurns.contains(turn.id)
                if turn.via == .imp, let sender = turn.sender { ExchangeChip(role: .reply, peer: sender) }
                MarkdownView(blocks: model.replyBlocks(turn.reply), base: Workspace.directory(for: model.id), fontSize: 13,
                             onImageLoad: measuring ? nil : { layout.onToggle?() },
                             mediaOwner: turn.id.uuidString, autoplay: fresh && model.prefs.autoplaysMedia && !measuring,
                             measuring: measuring)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Your side of a turn, everything that went to the Imp: how you asked (a shortcut, out loud),
/// your words or the shortcut's instruction, the text it was run on, and the picture.
private struct RequestCard: View {
    @Environment(\.impTint) private var tint
    let turn: ChatTurn
    let model: ImpModel
    let layout: BubbleLayout
    let measuring: Bool
    @State private var showAllText = false

    /// Copied text longer than this shows its start, with "Show all".
    private static let shortText = 280

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if turn.via == .imp, let sender = turn.sender {
                ExchangeChip(role: .asked, peer: sender)
            } else if turn.via == .answer, let sender = turn.sender {
                ExchangeChip(role: .answered, peer: sender)
            } else if let header {
                Label(header.title, systemImage: header.icon)
                    .font(Typeface.small.weight(.semibold))
                    .foregroundStyle(Tone.muted)
            }
            if turn.via == .shortcut {
                if let instruction = turn.instruction { Text(instruction).font(Typeface.body) }
            } else if !turn.request.isEmpty {
                Text(turn.request).font(Typeface.body)
            }
            if let copied = turn.copiedText, !copied.isEmpty { quote(copied) }
            let blocks = Self.attachmentBlocks(of: turn)
            if !blocks.isEmpty {
                MarkdownView(blocks: blocks,
                             base: Workspace.directory(for: model.id),
                             onImageLoad: measuring ? nil : { layout.onToggle?() }, measuring: measuring, imageHeight: 150)
            }
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.small)
        .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            .fill(([.imp, .answer].contains(turn.via) ? turn.sender.map { Color.imp($0.hue) } ?? tint : tint).opacity(Opacity.tintFill)))
    }

    /// The picture, sounds and videos that came with the request, shown from their saved files.
    private static func attachmentBlocks(of turn: ChatTurn) -> [MarkdownBlock] {
        ([turn.picture].compactMap { $0 } + (turn.files ?? [])).map { path in
            let url = URL(fileURLWithPath: path)
            if let kind = MarkdownBlock.MediaKind(url) {
                return .media(url: url, title: url.lastPathComponent, kind: kind, autoplay: false)
            }
            return .image(url: url, alt: String(localized: "Picture"), link: nil)
        }
    }

    /// Where it came from, when it wasn't simply typed.
    private var header: (title: String, icon: String)? {
        switch turn.via {
        case .shortcut?: (String(localized: "Trigger · \(turn.request)"), "bolt.fill")
        case .spoken?: (String(localized: "Said"), "mic.fill")
        case .typed?, .recap?, .imp?, .answer?, nil: nil
        }
    }

    /// The copied text a shortcut ran on, set off like a quotation.
    private func quote(_ text: String) -> some View {
        let long = text.count > Self.shortText
        return VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(long && !showAllText ? String(text.prefix(Self.shortText)) + "…" : text)
                .font(Typeface.body)
                .foregroundStyle(Tone.muted)
            if long {
                Button(showAllText ? "Show less" : "Show all") { showAllText.toggle() }
                    .buttonStyle(.plain)
                    .font(Typeface.small.weight(.semibold))
                    .foregroundStyle(LegibleTint(on: .raised))
            }
        }
        .padding(.leading, Spacing.small)
        .overlay(alignment: .leading) { Capsule().fill(Tone.faint).frame(width: BubbleMetrics.rule) }
    }
}
