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
    var measuring = false
    @State private var confirmingDelete = false

    /// Turns shown at first, and added by each page of earlier ones.
    static let page = 25
    /// The least height the transcript keeps, however much the text box grows.
    static let minTranscript: CGFloat = 80

    var body: some View {
        let history = model.history
        let live = model.chatWork
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().opacity(0.6)
            if let reason = model.sleepReason {
                Label("\(model.profile.name) is asleep. \(reason)", systemImage: "moon.zzz.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.recapError {
                Label("Couldn't recap: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if model.showsContextNotice {
                ContextNotice(model: model, changed: changed)
            }
            if history.turns.isEmpty && live == nil {
                Text("A new chat. Ask \(model.profile.name) anything below: it's saved, so you can come back to it from the list above.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                let shown = Array(history.latest(layout.chatPages * Self.page))
                let earlier = history.turns.count - shown.count
                // Turns above the latest recap are still here to read, but the model only has the recap.
                let recapped = shown.lastIndex { $0.via == .recap }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            // Thousands of turns are never laid out at once: a page at a time, the
                            // next one loading as you scroll up to the top (or with a click).
                            if earlier > 0 {
                                EarlierTurns(count: earlier, measuring: measuring) {
                                    showEarlier(from: shown.first?.id, reader)
                                }
                                .id(layout.chatPages)        // a fresh trigger for each page
                            }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, turn in
                                if turn.via == .recap {
                                    RecapCard(turn: turn, model: model, layout: layout, measuring: measuring)
                                } else {
                                    TurnView(turn: turn, steps: turn.steps.map(Bubble.Step.init), live: false,
                                             model: model, layout: layout, measuring: measuring)
                                        .opacity(recapped.map { index < $0 } == true ? 0.55 : 1)
                                }
                            }
                            // The request being worked on, live: its tools as they run, the answer as it streams.
                            if let live {
                                TurnView(turn: { var t = live.ask; t.reply = live.text; return t }(), steps: live.steps, live: true,
                                         model: model, layout: layout, measuring: measuring)
                            }
                            Color.clear.frame(height: 1).id(Self.end)
                        }
                        // The same room on both sides: no extra gutter on the right (the scroll bar
                        // brings its own when it shows).
                        .padding(.bottom, 4)
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
            await Task.yield()
            reader.scrollTo(oldest, anchor: .top)
        }
    }

    private func follow(_ reader: ScrollViewProxy, animated: Bool = true) {
        guard !measuring else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(Self.end, anchor: .bottom) }
        } else {
            reader.scrollTo(Self.end, anchor: .bottom)
        }
    }

    /// The chat you're in (a menu of the saved ones), then recap, new chat and delete.
    private var header: some View {
        HStack(spacing: 10) {
            // The title gives way (one line, cut at the end) so the buttons always keep their room.
            ChatPicker(model: model, changed: changed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            if model.isRecapping {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Recapping…").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
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
        .frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// The chat changed: start at its newest turns, and re-measure the bubble.
    private func changed() {
        layout.chatPages = 1
        confirmingDelete = false
        layout.onToggle?()
    }

    /// Two steps, since it can't be undone: the bin, then "Delete chat?" for a few seconds.
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
                Text("Delete chat?").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.red)
                    .lineLimit(1).fixedSize()
            } else {
                Image(systemName: "trash").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Delete this chat and \(model.profile.name)'s memory of it.")
        .accessibilityLabel("Delete chat")
    }
}

/// The current chat's name, opening a list of every saved chat to switch to (and a new one).
private struct ChatPicker: View {
    let model: ImpModel
    let changed: () -> Void
    /// The talks this Imp had with other Imps, newest first (read from every Imp's chats).
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
            HStack(spacing: 4) {
                if model.history.current.peer != nil { Image(systemName: "person.2.fill").font(.system(size: 10)) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).layoutPriority(1)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help("Your chats with \(model.profile.name). Pick one to carry on where you left off. Talks with other Imps open to read.")
        .task(id: model.history.chats.first?.updated) {
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
            HStack(spacing: 6) {
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                Text("\(count) earlier messages").font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help("Show earlier messages")
        .onAppear {
            // Scrolled up to the top: the next page comes in by itself. Only if it stays in view
            // a moment (a lazy stack may lay it out in passing while the chat opens at the bottom).
            guard !measuring else { return }
            inView = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if inView { once() }
            }
        }
        .onDisappear { inView = false }
    }

    private func once() {
        guard !loaded else { return }
        loaded = true
        load()
    }
}

/// A small icon button in the chat's header that asks first: the icon, then its question for a
/// few seconds (a second click does it).
private struct ConfirmButton: View {
    let icon: String
    let confirm: LocalizedStringKey
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        Button {
            if asking { asking = false; action() } else {
                asking = true
                Task { try? await Task.sleep(for: .seconds(3)); asking = false }
            }
        } label: {
            if asking {
                Text(confirm).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .lineLimit(1).fixedSize()
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A quiet suggestion, once per chat, when the chat has grown long enough to be slow and costly
/// (`ImpPreferences.contextNoticeTokens`). It never blocks anything: recap, start a new chat, or wave it away.
private struct ContextNotice: View {
    let model: ImpModel
    let changed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.badge.star").font(.system(size: 12)).foregroundStyle(.secondary)
            Text("This chat is getting long. A recap or a new chat keeps \(model.profile.name) quick.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if model.canRecap {
                Button("Recap") { model.dismissContextNotice(); model.recapChat() }
                    .buttonStyle(.imp(.secondary, small: true))
            }
            Button("New chat") { model.dismissContextNotice(); model.startNewChat(); changed() }
                .buttonStyle(.imp(.secondary, small: true))
            Button { model.dismissContextNotice(); changed() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Recap", systemImage: "rectangle.compress.vertical").font(.system(size: 11, weight: .semibold))
                Text(turn.date, format: .dateTime.day().month().hour().minute()).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                InfoTip("\(model.profile.name) remembers this recap instead of the messages above it (they stay here to read), plus the last message before it.")
            }
            .foregroundStyle(tint)
            MarkdownView(blocks: model.replyBlocks(turn.reply), base: Workspace.directory(for: model.id), fontSize: 12,
                         onImageLoad: measuring ? nil : { layout.onToggle?() }, measuring: measuring)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if live { Text("Now") } else { Text(turn.date, format: .dateTime.day().month().hour().minute()) }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            // Yours on the right; another Imp's on the left, in its colour.
            HStack {
                if turn.via != .imp { Spacer(minLength: 48) }
                RequestCard(turn: turn, model: model, layout: layout, measuring: measuring)
                if turn.via == .imp { Spacer(minLength: 48) }
            }
            if !steps.isEmpty {
                StepList(steps: steps, layout: layout, animated: live && !measuring)
            }
            if turn.failed {
                Label(turn.reply, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange)
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
        VStack(alignment: .leading, spacing: 6) {
            if turn.via == .imp, let sender = turn.sender {
                ExchangeChip(role: .asked, peer: sender)
            } else if let header {
                Label(header.title, systemImage: header.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if turn.via == .shortcut {
                if let instruction = turn.instruction { Text(instruction).font(.system(size: 13)) }
            } else if !turn.request.isEmpty {
                Text(turn.request).font(.system(size: 13))
            }
            if let copied = turn.copiedText, !copied.isEmpty { quote(copied) }
            if let picture = turn.picture {
                MarkdownView(blocks: [.image(url: URL(fileURLWithPath: picture), alt: String(localized: "Picture"), link: nil)],
                             base: Workspace.directory(for: model.id),
                             onImageLoad: measuring ? nil : { layout.onToggle?() }, measuring: measuring, imageHeight: 150)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((turn.via == .imp ? turn.sender.map { Color.imp($0.hue) } ?? tint : tint).opacity(0.16)))
    }

    /// Where it came from, when it wasn't simply typed.
    private var header: (title: String, icon: String)? {
        switch turn.via {
        case .shortcut?: (String(localized: "Trigger · \(turn.request)"), "bolt.fill")
        case .spoken?: (String(localized: "Said"), "mic.fill")
        case .typed?, .recap?, .imp?, nil: nil
        }
    }

    /// What a shortcut was run on, set off like a quotation.
    private func quote(_ text: String) -> some View {
        let long = text.count > Self.shortText
        return VStack(alignment: .leading, spacing: 3) {
            Text(long && !showAllText ? String(text.prefix(Self.shortText)) + "…" : text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if long {
                Button(showAllText ? "Show less" : "Show all") { showAllText.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 2) }
    }
}
