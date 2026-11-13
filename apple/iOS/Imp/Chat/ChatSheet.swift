import ImpDesign
import ImpKit
import QuickLook
import SwiftUI

/// An Imp's sheet: everything about one Imp in one place. Its chat with you and its talks with other
/// Imps are two sides of it (`ImpPane`), its settings are one tap away, and it wears the Imp's colour.
/// While it rests at half height the Imp itself waits in the room above it.
///
/// The chat shows the turns its source has and sends what you type: the Mac does the
/// thinking for its Imps, this iPhone for the pocket ones.
/// Replies are drawn from their Markdown like the Mac's bubble: text, lists, code and tables, and
/// the pictures, voices, videos and files they show, fetched from the Mac (`LinkFileStore`).
struct ImpSheet: View {
    /// Where files in replies come from (the Mac).
    let hub: LinkHub
    let source: any ChatSource
    /// The Imps hatched here: their chats hold half of every talk.
    let pocket: PocketRuntime
    let impID: UUID
    /// The side that is shown: the chat with you, or the talks with other Imps.
    @Binding var pane: ImpPane
    /// The room is in view above the sheet, and the Imp itself is up there.
    var roomInView = false
    /// Opens the Imp's settings. Only the Imps hatched on this iPhone have any.
    var edit: (() -> Void)?
    /// Starts waking an Imp that has no Brain (the first run). Only the Imps hatched here have it.
    /// Opens the Brain panel of this pocket Imp's editor.
    var giveBrain: (() -> Void)?
    /// Close: back to where the sheet was opened from.
    var close: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var confirmingNewChat = false
    /// A file to look at full screen (Quick Look).
    @State private var preview: URL?
    @State private var problem: String?
    /// Voices in replies that arrive after this play on their own (older ones wait for a tap).
    @State private var openedAt = Date()
    /// The bottom of the transcript is on screen (otherwise a jump-to-latest button shows).
    @State private var atEnd = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var imp: LinkImp? { source.imp(impID) }
    private var turns: [LinkTurn] { source.turns(impID) }
    private var availability: ChatAvailability { source.availability(impID) }
    /// Work you asked for. A question from another Imp shows as its speech bubble on the stage.
    private var work: LinkWork? { source.working(impID).flatMap { $0.from == nil ? $0 : nil } }
    private var canStartOver: Bool { availability != .offline && !(turns.isEmpty && work == nil) }

    var body: some View {
        VStack(spacing: 0) {
            if let imp {
                header(imp)
                switch pane {
                case .chat:
                    transcript(imp)
                    composer(imp)
                case .talks:
                    TalksPane(hub: hub, pocket: pocket, impID: impID)
                }
            } else {
                // The Imp went home while the chat was open.
                ContentUnavailableView("This Imp has gone home", systemImage: "house")
                    .foregroundStyle(Tone.muted)
            }
        }
        .presentationBackground(Tone.surface)
        // An Imp's sheet wears the Imp's colour (principle 4): its buttons, its switch and what you said.
        .impControls(tint: imp.map { Color.imp($0.hue) } ?? Tone.accent)
        .environment(\.openURL, OpenURLAction { url in open(url) })
        .quickLookPreview($preview)
        .impAnimation(ImpDesign.Motion.smooth, value: pane)
        .overlay(alignment: .top) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.caption)
                    .foregroundStyle(Tone.text)
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
                    .background(Tone.raised, in: Capsule())
                    .padding(.top, Sizing.toastTop)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: problem) {
                        try? await Task.sleep(for: .seconds(3))
                        withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { self.problem = nil }
                    }
            }
        }
        .impAnimation(ImpDesign.Motion.settle, value: problem)
        .confirmationDialog("Start a new chat?", isPresented: $confirmingNewChat, titleVisibility: .visible) {
            Button("phone.chat.new") {
                source.newChat(impID)
                openedAt = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } message: {
            if let imp { Text(source.newChatNote(imp)) }
        }
    }

    // MARK: Header

    /// The same bar in every sheet: who or what it is about on the leading side, Close on the trailing side.
    /// While the room is in view the Imp itself is up there, so the bar shows no second one.
    private func header(_ imp: LinkImp) -> some View {
        HStack(spacing: Spacing.medium) {
            // The talks are a side room, opened from the bar of the chat: one way back to the chat.
            if pane == .talks {
                HoverIconButton(systemName: "chevron.left", help: "common.back", tint: Tone.text) { pane = .chat }
                    .padding(.leading, -Spacing.small)
            } else if !roomInView {
                LiveImp(imp: imp, mood: mood).frame(width: Sizing.impPortrait, height: Sizing.impPortrait)
                    .transition(.scale.combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(imp.name).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Spacing.snug) {
                    if pane == .chat { Circle().fill(statusColor).frame(width: Spacing.snug, height: Spacing.snug) }
                    Text(pane == .talks ? String(localized: "menu.imp.talks") : status)
                        .font(Typeface.small)
                        .foregroundStyle(Tone.muted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: Spacing.small)
            // Each action is one tap away.
            if pane == .chat {
                // Only when this Imp has talked with other Imps.
                if !Talks.threads(of: impID, hub: hub, pocket: pocket).isEmpty {
                    HoverIconButton(systemName: "bubble.left.and.bubble.right", help: "menu.imp.talks", tint: Tone.text) { pane = .talks }
                }
                HoverIconButton(systemName: "square.and.pencil", help: "phone.chat.new", tint: Tone.text) { confirmingNewChat = true }
                    .disabled(!canStartOver)
            }
            if let edit {
                HoverIconButton(systemName: "slider.horizontal.3", help: "phone.chat.edit_help", tint: Tone.text, action: edit)
            }
            HoverIconButton(systemName: "xmark", help: "common.close", tint: Tone.text, action: close)
        }
        .padding(.leading, Spacing.page).padding(.trailing, Spacing.medium).padding(.top, Spacing.medium).padding(.bottom, Spacing.small)
        .impAnimation(ImpDesign.Motion.quick, value: status)
        .impAnimation(ImpDesign.Motion.smooth, value: roomInView)
    }

    private var mood: Mood {
        if availability != .ready { return .sleepy }
        if let m = source.mood(impID) { return m }
        return work != nil ? .working : .idle
    }

    private var status: String {
        switch availability {
        case .offline: return String(localized: "Asleep")
        case .noBrain: return String(localized: "phone.chat.no_brain")
        case .ready: break
        }
        if let work { return work.status ?? (work.partial.isEmpty ? String(localized: "Thinking…") : String(localized: "Answering…")) }
        if let w = source.working(impID), let from = w.from { return words("phone.chat.answering", from) }
        return source.restingStatus
    }

    private var statusColor: Color {
        if availability != .ready { return Tone.muted }
        return source.working(impID) != nil ? Tone.accentBright : Tone.good
    }

    // MARK: Transcript

    private func transcript(_ imp: LinkImp) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Spacing.page) {
                    if turns.isEmpty && work == nil { emptyState(imp) }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        if let label = Self.separator(turn.date, after: i > 0 ? turns[i - 1].date : nil) {
                            DaySeparator(text: label)
                        }
                        TurnView(turn: turn, imp: imp, hub: hub, fresh: turn.date > openedAt,
                                 retry: availability == .ready ? { source.ask(impID, turn.request) } : nil)
                    }
                    if let work { LiveTurn(work: work, imp: imp, hub: hub) }
                    Color.clear.frame(height: Stroke.hairline).id("end")
                        .onAppear { atEnd = true }
                        .onDisappear { atEnd = false }
                }
                .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.large)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .bottomTrailing) {
                if !atEnd && !(turns.isEmpty && work == nil) {
                    Button {
                        withImpAnimation(ImpDesign.Motion.spring, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.icon(.large, weight: .bold))
                            .foregroundStyle(Tone.text)
                            .frame(width: Sizing.hit, height: Sizing.hit)
                            .background(Tone.raised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(Spacing.medium)
                    .accessibilityLabel("phone.chat.jump_latest")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .impAnimation(ImpDesign.Motion.settle, value: atEnd)
            .dismissesKeyboard()
            .onChange(of: turns.last?.id) { _, _ in
                withImpAnimation(ImpDesign.Motion.spring, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) }
                if turns.last?.date ?? .distantPast > openedAt {
                    UINotificationFeedbackGenerator().notificationOccurred(turns.last?.failed == true ? .error : .success)
                }
            }
            .onChange(of: work?.partial) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: work == nil) { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: focused) { _, on in if on { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) } } }
        }
    }

    /// "Today 14:05" when a new day starts, or after a long pause.
    static func separator(_ date: Date, after previous: Date?) -> String? {
        if let previous, Calendar.current.isDate(previous, inSameDayAs: date), date.timeIntervalSince(previous) < 3_600 { return nil }
        let day: String
        if Calendar.current.isDateInToday(date) { day = String(localized: "Today") }
        else if Calendar.current.isDateInYesterday(date) { day = String(localized: "Yesterday") }
        else { day = date.formatted(.dateTime.weekday(.wide).day().month()) }
        return "\(day) \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func emptyState(_ imp: LinkImp) -> some View {
        let intro = source.intro(imp, availability)
        return VStack(spacing: Spacing.cozy) {
            Image(systemName: availability != .ready ? "moon.zzz" : "bubble.left.and.text.bubble.right")
                .font(.icon(.huge, weight: .light)).foregroundStyle(LegibleTint())
            HStack(spacing: 0) {
                Text(intro.title)
                    .font(Typeface.cardTitle).foregroundStyle(Tone.text)
                InfoTip(verbatim: intro.text)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.vast).padding(.horizontal, Spacing.page)
    }

    // MARK: Composer

    private func composer(_ imp: LinkImp) -> some View {
        VStack(spacing: Spacing.small) {
            let peers = availability == .ready ? source.peers(impID) : []
            if !peers.isEmpty && text.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.small) {
                        ForEach(peers) { other in
                            Button {
                                text = words("phone.chat.ask_to", other.name)
                                focused = true
                            } label: {
                                HStack(spacing: Spacing.snug) {
                                    Circle().fill(Color.imp(other.hue)).frame(width: Spacing.small, height: Spacing.small)
                                    Text(other.name).font(Typeface.label)
                                }
                                .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.snug)
                                .frame(minHeight: Sizing.hit)
                                .background(Tone.card, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Tone.text)
                            .accessibilityHint(Text(words("phone.chat.ask_to.hint", other.name)))
                        }
                    }
                    .padding(.horizontal, Spacing.large)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            switch availability {
            case .offline:
                asleepLine(imp)
            case .noBrain:
                if let giveBrain {
                    Button(action: giveBrain) { Label(words("firstrun.wake", imp.name), systemImage: "sparkles") }
                        .buttonStyle(.quiet)
                } else {
                    // A visitor: its brain is set up on its home.
                    asleepLine(imp)
                }
            case .ready:
                EmptyView()
            }
            HStack(alignment: .bottom, spacing: Spacing.cozy) {
                TextField(words("phone.chat.message", imp.name), text: $text, axis: .vertical)
                    .font(Typeface.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .foregroundStyle(Tone.text)
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
                    .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                if work != nil && trimmed.isEmpty {
                    Button { source.stop(impID); UIImpactFeedbackGenerator(style: .medium).impactOccurred() } label: { glyph("stop.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) { glyph("arrow.up") }
                        .buttonStyle(.plain)
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? Opacity.disabled : 1)
                        .accessibilityLabel("Send")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .impAnimation(ImpDesign.Motion.settle, value: work == nil)
            .padding(.horizontal, Spacing.roomy)
            .disabled(availability != .ready)
            .opacity(availability == .ready ? 1 : Opacity.disabled)
        }
        .padding(.vertical, Spacing.cozy)
    }

    /// An Imp that cannot answer: one line, with the longer words behind the help icon.
    private func asleepLine(_ imp: LinkImp) -> some View {
        let intro = source.intro(imp, availability)
        return SectionHeader(verbatimInfo: intro.text, minHeight: nil) {
            Label(intro.title, systemImage: "moon.zzz").font(Typeface.caption).foregroundStyle(Tone.muted)
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.icon(.big, weight: .bold))
            .foregroundStyle(OnTint())
            .frame(width: Sizing.hit, height: Sizing.hit)
            .background(Circle().fill(TintFill()))
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        source.ask(impID, trimmed)
        text = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Links

    /// Web links open in Safari; a file on the Mac comes over and opens in Quick Look.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let scheme = url.scheme?.lowercased(), scheme != "file" { return .systemAction }
        let ref = url.absoluteString
        Task {
            do { preview = try await hub.files.file(imp: impID, ref: ref) }
            catch { problem = error.localizedDescription }
        }
        return .handled
    }
}

// MARK: - Turns

private struct DaySeparator: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Typeface.small.weight(.semibold))
            .foregroundStyle(Tone.muted)
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.tight)
            .background(Tone.card, in: Capsule())
            .padding(.top, Spacing.tight)
    }
}

/// What you asked: on the right, on the Imp's colour.
private struct AskBubble: View {
    var text: String
    var retry: (() -> Void)?

    var body: some View {
        Text(Inline.text(text))
            .font(Typeface.body)
            .foregroundStyle(OnTint())
            .tint(OnTint())
            .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
            .background(TintFill(),
                        in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                if let retry { Button(action: retry) { Label("phone.chat.ask_again", systemImage: "arrow.clockwise") } }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Sizing.marker)
    }
}

private struct TurnView: View {
    var turn: LinkTurn
    var imp: LinkImp
    var hub: LinkHub
    /// Arrived while the chat was open (its voice may play on its own).
    var fresh: Bool
    var retry: (() -> Void)?
    @AppStorage(PhonePrefs.autoplayKey) private var autoplayVoices = true

    var body: some View {
        VStack(spacing: Spacing.small) {
            AskBubble(text: turn.request, retry: retry)
            if !turn.steps.isEmpty { StepsLine(steps: turn.steps) }
            ReplyCard(text: turn.reply, imp: imp, hub: hub, failed: turn.failed, autoplay: fresh && autoplayVoices, retry: turn.failed ? retry : nil)
        }
    }
}

/// The tools it used, folded into one line ("Ran 3 tools ›"); tap to list them.
private struct StepsLine: View {
    var steps: [String]
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Button { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { open.toggle() } } label: {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "gearshape.2.fill").font(.icon(.small))
                    Text(steps.count == 1 ? steps[0] : words("phone.chat.ran_tools", steps.count))
                        .lineLimit(1)
                    if steps.count > 1 {
                        Image(systemName: "chevron.right").font(.icon(.tiny, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(Typeface.small.weight(.medium))
                .foregroundStyle(Tone.muted)
                .frame(minHeight: Sizing.hit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(steps.count < 2)
            if open {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark").labelStyle(.titleAndIcon)
                    }
                }
                .font(Typeface.small)
                .foregroundStyle(Tone.muted)
                .padding(.leading, Spacing.large)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Spacing.small)
    }
}

/// The Imp's answer: its Markdown, drawn block by block, in a card on the left.
private struct ReplyCard: View {
    var text: String
    var imp: LinkImp
    var hub: LinkHub
    var failed = false
    var streaming = false
    var autoplay = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if failed {
                // What went wrong is behind the badge, not spelled out in the chat.
                HStack(spacing: Spacing.snug) {
                    Text("phone.chat.failed")
                        .font(Typeface.label)
                        .foregroundStyle(Tone.text)
                    if !text.isEmpty { IssueBadge(text: text) }
                    Spacer(minLength: Spacing.small)
                    if let retry {
                        HoverIconButton(systemName: "arrow.clockwise", help: "common.try_again", tint: Tone.text, action: retry)
                    }
                }
            } else {
                ReplyBlocks(text: text, imp: imp, hub: hub, autoplay: autoplay)
                if streaming { TypingDots(compact: true) }
            }
        }
        .padding(.horizontal, Spacing.roomy).padding(.vertical, failed ? Spacing.snug : Spacing.medium)
        .background(failed ? AnyShapeStyle(Tone.errorBackground) : AnyShapeStyle(Tone.card),
                    in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
        .contextMenu {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            if !streaming { ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, Spacing.huge)
    }
}

/// The answer being written: your message, what it's doing, the words so far.
private struct LiveTurn: View {
    var work: LinkWork
    var imp: LinkImp
    var hub: LinkHub

    var body: some View {
        VStack(spacing: Spacing.small) {
            AskBubble(text: work.request)
            if let status = work.status {
                HStack(spacing: Spacing.snug) {
                    ProgressView().controlSize(.mini).tint(Tone.muted)
                    Text(status).lineLimit(1)
                }
                .font(Typeface.small.weight(.medium))
                .foregroundStyle(Tone.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Spacing.small)
            }
            if work.partial.isEmpty {
                TypingDots().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ReplyCard(text: work.partial, imp: imp, hub: hub, streaming: true)
            }
        }
    }
}

struct TypingDots: View {
    var compact = false
    var body: some View {
        PacedTimeline(activity: .calm) { date in
            let t = date.timeIntervalSinceReferenceDate
            HStack(spacing: Spacing.snug) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Tone.muted).frame(width: compact ? Spacing.snug : Spacing.small, height: compact ? Spacing.snug : Spacing.small)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, compact ? 0 : Spacing.roomy).padding(.vertical, compact ? Spacing.hairline : Spacing.medium)
            .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(Tone.card), in: Capsule())
        }
        .accessibilityLabel("Writing")
    }
}
