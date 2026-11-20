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
    /// Whether you are typing, for the Imp in the bar. Held apart from the sheet: the sheet (and so the whole
    /// transcript) must not be drawn again each time the field gains focus.
    @State private var typing = TypingState()
    @State private var confirmingNewChat = false
    /// A file to look at full screen (Quick Look).
    @State private var preview: URL?
    @State private var problem: String?
    /// Voices in replies that arrive after this play on their own (older ones wait for a tap).
    @State private var openedAt = Date()
    /// The Imp whose talk is open in the talks pane, if one is.
    @State private var talkPeer: UUID?
    /// The bottom of the transcript is on screen (otherwise a jump-to-latest button shows).
    @State private var atEnd = true
    /// Whether the transcript is being scrolled (a finger, a fling, a scroll to the latest). Not observed:
    /// it only decides how the next change of where the transcript is gets read.
    @State private var scrolling = ScrollMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var imp: LinkImp? { source.imp(impID) }
    private var turns: [LinkTurn] { source.turns(impID) }
    private var availability: ChatAvailability { source.availability(impID) }
    /// Work you asked for. A question from another Imp shows as its speech bubble on the stage.
    private var work: LinkWork? { source.working(impID).flatMap { $0.from == nil ? $0 : nil } }
    private var canStartOver: Bool { availability != .offline && !(turns.isEmpty && work == nil) }
    /// The name of the talk's other Imp while one talk is open in the talks pane.
    private var talkTitle: String? {
        talkPeer.flatMap { id in Talks.threads(of: impID, hub: hub, pocket: pocket).first { $0.peer.id == id }?.peer.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let imp {
                header(imp)
                switch pane {
                case .chat:
                    transcript(imp)
                    Composer(source: source, impID: impID, imp: imp, typing: typing, giveBrain: giveBrain)
                case .talks:
                    TalksPane(hub: hub, pocket: pocket, impID: impID, peer: $talkPeer)
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
        .onChange(of: pane) { _, new in if new == .chat { talkPeer = nil } }
        // The Talks button shows once there are talks: the homes that keep them are asked as the sheet opens.
        .task(id: impID) { Talks.refresh(impID, hub: hub) }
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
                Haptics.notify(.success)
            }
        } message: {
            if let imp { Text(source.newChatNote(imp)) }
        }
    }

    // MARK: Header

    /// The same bar in every sheet: who or what it is about on the leading side, Close on the trailing side.
    /// While the room is in view the Imp itself is up there, so the bar shows no second one. Otherwise
    /// (the sheet stands at full height, or the keyboard lifted it) the bar shows the Imp as the room
    /// does: its mood, what it acts out (`ChatSource.act`), and it watches what you type.
    private func header(_ imp: LinkImp) -> some View {
        HStack(spacing: Spacing.medium) {
            // The talks are a side room, opened from the bar of the chat. One talk open: the bar names it, and
            // its back goes to the list. The list: its back goes to the chat.
            if pane == .talks {
                HoverIconButton(systemName: "chevron.left", help: "common.back", tint: Tone.text) {
                    if talkPeer != nil { talkPeer = nil } else { pane = .chat }
                }
                .padding(.leading, -Spacing.small)
            } else {
                // Always in the bar, so the keyboard lifting the sheet only fades it in: nothing is built or
                // laid out then. It is not drawn at all while the room above shows the Imp.
                HeaderPortrait(imp: imp, mood: mood, performance: source.act(impID), typing: typing)
                    .frame(width: roomInView ? 0 : Sizing.impPortrait, height: Sizing.impPortrait)
                    .opacity(roomInView ? 0 : 1)
                    .environment(\.covered, roomInView)
                    .padding(.trailing, roomInView ? -Spacing.medium : 0)
                    .accessibilityHidden(roomInView)
            }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(talkTitle ?? imp.name).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Spacing.snug) {
                    if pane == .chat {
                        // A state that has a picture shows it. Otherwise the dot says ready or busy.
                        if let symbol = statusSymbol {
                            Image(systemName: symbol).font(.icon(.small)).foregroundStyle(statusColor)
                                .accessibilityHidden(true)
                        } else {
                            Circle().fill(statusColor).frame(width: Spacing.snug, height: Spacing.snug)
                        }
                    }
                    Text(pane == .talks ? String(localized: talkPeer == nil ? "menu.imp.talks" : "phone.talks.one") : status)
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
        // The portrait comes and goes as the keyboard lifts the sheet. The bar keeps its height, so the chat
        // under it is not pushed around while the keyboard moves.
        .frame(minHeight: Sizing.impPortrait)
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

    private var statusSymbol: String? {
        switch availability {
        case .offline: return ImpStateSymbol.asleep
        case .noBrain: return ImpStateSymbol.noBrain
        case .ready: return source.working(impID) == nil ? source.restingSymbol : nil
        }
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
                        // Equatable: a row is built again only when it changed, not each time the sheet is drawn.
                        TurnView(turn: turn, imp: imp, hub: hub, answererHue: turn.answer == true ? source.peers(impID).first { $0.name == turn.from }?.hue : nil, fresh: turn.date > openedAt,
                                 canRetry: availability == .ready, ask: { [source, impID] in source.ask(impID, $0) })
                            .equatable()
                    }
                    if let work { LiveTurn(work: work, imp: imp, hub: hub) }
                    Color.clear.frame(height: Stroke.hairline).id("end")
                }
                .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.large)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Opens at the latest, and stays there as it grows only while you are there. Whether you are is
            // read from where the scroll is, not from a row appearing: a row that grows at the bottom (Ran 3
            // tools, opened) made that flip on and off with the anchor pulling back, and the app hung.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(atEnd ? .bottom : .top, for: .sizeChanges)
            // Leaving the latest counts only while the transcript is scrolled. The keyboard coming or going
            // changes the visible height, and for a moment the bottom looks out of reach: read then, the anchor
            // let go of the bottom, the latest slid behind the keyboard and the jump button flickered.
            .onScrollGeometryChange(for: Bool.self) { Self.isAtEnd($0) } action: { _, isAtEnd in
                if atEnd != isAtEnd, isAtEnd || scrolling.on { atEnd = isAtEnd }
            }
            .onScrollPhaseChange { _, phase, context in
                scrolling.on = phase != .idle
                let isAtEnd = Self.isAtEnd(context.geometry)
                if atEnd != isAtEnd { atEnd = isAtEnd }
            }
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
            .tapClosesKeyboard()
            .onChange(of: turns.last?.id) { _, _ in
                withImpAnimation(ImpDesign.Motion.spring, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) }
                if turns.last?.date ?? .distantPast > openedAt {
                    Haptics.notify(turns.last?.failed == true ? .error : .success)
                }
            }
            .onChange(of: work?.partial) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: work?.reasoning.isEmpty) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: work == nil) { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    /// The bottom of the transcript is in view, give or take a little.
    private static func isAtEnd(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY < Spacing.huge
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
                .accessibilityHidden(true)
            // An Imp that can't answer is explained once, in the card above the field: not here as well.
            if availability == .ready {
                // Centred on the title alone: the tip hangs beside it.
                Text(intro.title)
                    .font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .multilineTextAlignment(.center)
                    .hangingTip(InfoTip(verbatim: intro.text))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.vast).padding(.horizontal, Spacing.page)
    }

    // MARK: Links

    /// Web links open in Safari. A file on the Mac comes over and opens in Quick Look.
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

// MARK: - Composer

/// See `ImpSheet.scrolling`.
private final class ScrollMotion {
    var on = false
}

/// What stands between you and asking the Imp, above the field: it is asleep, has no brain yet, or can only
/// talk here. One look for all of them: a card as wide as the field's row (the caller gives the row's
/// inset), the symbol, a short title and the reason under it, and what can be done: an action under the
/// words, a close button in the corner. The same room on every side, whatever it holds.
struct ComposerNotice<Action: View>: View {
    var symbol: String
    var title: String
    var text: String
    var close: (() -> Void)?
    @ViewBuilder var action: Action

    init(symbol: String, title: String, text: String, close: (() -> Void)? = nil, @ViewBuilder action: () -> Action) {
        self.symbol = symbol; self.title = title; self.text = text; self.close = close; self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Image(systemName: symbol)
                .font(.icon(.small))
                .foregroundStyle(Tone.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.small) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(verbatim: title).font(Typeface.caption.weight(.semibold)).foregroundStyle(Tone.text)
                    Text(verbatim: text).font(Typeface.small).foregroundStyle(Tone.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                action
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                // The close button keeps its finger-sized target, but not its size in the card's layout.
                HoverIconButton(systemName: "xmark", help: "common.close", tint: Tone.muted, action: close)
                    .padding(-Spacing.small)
            }
        }
        .padding(Spacing.medium)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
}

extension ComposerNotice where Action == EmptyView {
    init(symbol: String, title: String, text: String, close: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, text: text, close: close) { EmptyView() }
    }
}

/// A set of Imp ids kept as one line of text (for `@AppStorage`).
struct DismissedNotices {
    private var ids: Set<UUID>

    init(raw: String) { ids = Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }) }

    var raw: String { ids.map(\.uuidString).sorted().joined(separator: ",") }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    mutating func insert(_ id: UUID) { ids.insert(id) }
    mutating func remove(_ id: UUID) { ids.remove(id) }
}

/// What the bar's Imp needs to know of the composer, kept out of the sheet's own state.
@MainActor @Observable
final class TypingState {
    var on = false
}

/// The Imp in the sheet's bar: it watches the field while you type.
private struct HeaderPortrait: View {
    var imp: LinkImp
    var mood: Mood
    var performance: Performance?
    var typing: TypingState

    /// From the bar's leading corner, the field you type in is below and to the right.
    private static let lookAtComposer = CGPoint(x: 0.35, y: 0.9)

    var body: some View {
        LiveImp(imp: imp, mood: mood, performance: performance,
                gaze: typing.on ? Self.lookAtComposer : nil, attentive: typing.on)
    }
}

/// The field you write in, with its send button, the other Imps to ask, and what stands in for them when the
/// Imp cannot answer. It owns what is typed and the focus, so typing draws this and nothing else.
private struct Composer: View {
    let source: any ChatSource
    let impID: UUID
    let imp: LinkImp
    let typing: TypingState
    var giveBrain: (() -> Void)?
    @State private var text = ""
    /// The other Imp the message is for (picked with the @ button), if any.
    @State private var askedPeer: LinkImp?
    @FocusState private var focused: Bool
    @AppStorage(PhonePrefs.dismissedWithheldKey) private var dismissedRaw = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var availability: ChatAvailability { source.availability(impID) }
    private var working: Bool { source.working(impID).flatMap { $0.from == nil ? $0 : nil } != nil }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: Spacing.small) {
            // Whatever stands in the way of asking, said the same way: one card, as wide as the row under it.
            Group {
                switch availability {
                case .offline:
                    asleepNotice
                case .noBrain:
                    // One hatched here is woken from here. A visitor's brain is set up on its home.
                    if let giveBrain {
                        ComposerNotice(symbol: "moon.zzz", title: source.intro(imp, availability).title,
                                       text: source.intro(imp, availability).text) {
                            Button(action: giveBrain) { Label(words("firstrun.wake", imp.name), systemImage: "sparkles") }
                                .buttonStyle(.imp(.primary, small: true))
                        }
                    } else {
                        asleepNotice
                    }
                case .ready:
                    if let withheld = source.toolsWithheld(impID), !dismissed.contains(impID) {
                        ComposerNotice(symbol: "lock.fill", title: withheld.title, text: withheld.text, close: {
                            withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { dismissed.insert(impID) }
                        })
                    }
                }
            }
            .padding(.horizontal, Spacing.roomy)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            HStack(alignment: .bottom, spacing: Spacing.cozy) {
                field
                if working && trimmed.isEmpty {
                    Button { source.stop(impID); Haptics.tap(.medium) } label: { glyph("stop.fill") }
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
            .impAnimation(ImpDesign.Motion.settle, value: working)
            .padding(.horizontal, Spacing.roomy)
            .disabled(availability != .ready)
            .opacity(availability == .ready ? 1 : Opacity.disabled)
        }
        .padding(.vertical, Spacing.cozy)
        .onChange(of: focused) { _, on in typing.on = on }
        // Put away once, the notice stays away until the Imp may use its tools again and then loses them anew.
        .onChange(of: source.toolsWithheld(impID) == nil, initial: true) { _, allowed in
            if allowed, dismissed.contains(impID) { dismissed.remove(impID) }
        }
    }

    /// The Imps whose "only talks here" notice was put away, kept across launches.
    private var dismissed: DismissedNotices {
        get { DismissedNotices(raw: dismissedRaw) }
        nonmutating set { dismissedRaw = newValue.raw }
    }

    /// The text field in its rounded well. The other Imps you can ask are one small button at its leading
    /// edge, inside the well, so the bar is no taller or wider for them.
    ///
    /// How it lines up, by construction rather than by nudging:
    /// - The `@` is one line of text in the field's own font, with the field's own padding above and below,
    ///   so its box is exactly the box of one line of the field. The row aligns their bottoms: the `@` sits on
    ///   the field's last line however many lines there are. (Aligned by text baseline, it drifted: a `Menu`
    ///   doesn't pass its label's baseline on, so its bottom edge stood in for it.)
    /// - The well is at least as tall as the send button, with what is in it centred, so a single line is
    ///   centred on the button too.
    /// - The placeholder is the field's own prompt, in the field's font: it lies exactly where typing starts.
    private var field: some View {
        let peers = availability == .ready ? source.peers(impID) : []
        return HStack(alignment: .bottom, spacing: Spacing.tight) {
            if !peers.isEmpty { peerMenu(peers) }
            TextField(text: $text, prompt: Text(words("phone.chat.message", imp.name)).foregroundStyle(Tone.muted), axis: .vertical) {
                Text(words("phone.chat.message", imp.name))
            }
            .lineLimit(1...6)
            .focused($focused)
            .foregroundStyle(Tone.text)
            .padding(.vertical, Self.linePadding)
        }
        .font(Typeface.body)
        .frame(minHeight: Sizing.hit)
        .padding(.leading, peers.isEmpty ? Spacing.roomy : Spacing.cozy).padding(.trailing, Spacing.roomy)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
    }

    /// Above and below a line in the well: the field's and the `@`'s, the same, so their boxes match.
    private static let linePadding = Spacing.small

    /// The Imps this one can be asked to message: picking one starts the message ("Ask Pip to ") and
    /// brings the keyboard up. Each wears its colour in the menu. The button is a bare grey glyph on the
    /// text's line, so the field keeps its room for words.
    private func peerMenu(_ peers: [LinkImp]) -> some View {
        Group {
            if let asked = askedPeer {
                // The chosen Imp shows as its colour: a tap puts the @ back, so another can be chosen.
                Button { askedPeer = nil; Haptics.tap(.light) } label: {
                    // The same box as the @ (one line of text with the same padding), so the circle, drawn
                    // over it at its own size, is centred on that line exactly as the @ is.
                    Text(Image(systemName: "at"))
                        .foregroundStyle(.clear)
                        .padding(.vertical, Self.linePadding)
                        .frame(minWidth: Spacing.page)
                        .overlay {
                            Circle().fill(Color.imp(asked.hue))
                                .frame(width: Sizing.dot * 2, height: Sizing.dot * 2)
                        }
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(words("phone.chat.ask_to.hint", asked.name))
            } else {
                Menu {
                    ForEach(peers) { other in
                        Button { mention(other) } label: {
                            Label { Text(verbatim: other.name) } icon: { ImpSwatch.image(hue: other.hue) }
                        }
                        .accessibilityHint(Text(words("phone.chat.ask_to.hint", other.name)))
                    }
                } label: {
                    // One line of the field's text (its font comes from the well, its padding is the field's): see `field`.
                    // Grey like the prompt.
                    Text(Image(systemName: "at"))
                        .foregroundStyle(Tone.muted)
                        .padding(.vertical, Self.linePadding)
                        .frame(minWidth: Spacing.page)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("phone.chat.peers")
            }
        }
        .buttonStyle(.plain)
    }

    /// Picks the Imp a message is for. Nothing is written in the field: the message starts with "Ask <name> To:" when sent.
    private func mention(_ other: LinkImp) {
        askedPeer = other
        focused = true
    }

    /// An Imp that cannot answer now (its home is away, or has no brain for it): why, and what to do.
    private var asleepNotice: some View {
        let intro = source.intro(imp, availability)
        return ComposerNotice(symbol: "moon.zzz", title: intro.title, text: intro.text)
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.icon(.big, weight: .bold))
            .foregroundStyle(OnTint())
            .frame(width: Sizing.hit, height: Sizing.hit)
            .background(Circle().fill(TintFill()))
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        let message = askedPeer.map { words("phone.chat.ask_to_prefix", $0.name) + trimmed } ?? trimmed
        source.ask(impID, message)
        text = ""
        askedPeer = nil
        Haptics.tap(.light)
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

/// An Imp's answer to a message this one sent without waiting: on the left, in that Imp's colour, under "Bo answered".
private struct AnswerBubble: View {
    var text: String
    var from: String
    var hue: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Label { Text(verbatim: String(format: String(localized: "exchange.answered"), from)) } icon: { ImpSwatch.image(hue: hue) }
                .font(Typeface.small.weight(.semibold))
                .foregroundStyle(Tone.muted)
            Text(Inline.text(text))
                .font(Typeface.body)
                .foregroundStyle(Tone.text)
                .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
                .background(Color.imp(hue).opacity(0.22), in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                .contextMenu { Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, Sizing.marker)
    }
}

private struct TurnView: View, Equatable {
    var turn: LinkTurn
    var imp: LinkImp
    var hub: LinkHub
    /// The colour of the Imp that answered, when this turn is its answer to a message sent without waiting.
    var answererHue: Double?
    /// Arrived while the chat was open (its voice may play on its own).
    var fresh: Bool
    /// Ask again is offered (the Imp can answer). `ask` is what it does, and is left out of the comparison.
    var canRetry: Bool
    var ask: (String) -> Void
    @AppStorage(PhonePrefs.autoplayKey) private var autoplayVoices = true

    nonisolated static func == (a: TurnView, b: TurnView) -> Bool {
        a.turn == b.turn && a.imp == b.imp && a.answererHue == b.answererHue && a.fresh == b.fresh && a.canRetry == b.canRetry && a.hub === b.hub
    }

    var body: some View {
        let retry: (() -> Void)? = canRetry ? { ask(turn.request) } : nil
        VStack(spacing: Spacing.small) {
            if turn.answer == true {
                AnswerBubble(text: turn.request, from: turn.from ?? "", hue: answererHue ?? imp.hue)
            } else {
                AskBubble(text: turn.request, retry: retry)
            }
            StepsBlock(turn: turn)
            ReplyCard(text: turn.reply, imp: imp, hub: hub, failed: turn.failed, autoplay: fresh && autoplayVoices, retry: turn.failed ? retry : nil)
        }
    }
}

/// What the Imp did on the way, in order: each thinking phase is a line of its own ("Thought for 3s ›"), the tools
/// between two of them are folded into one line.
private struct StepsBlock: View {
    var turn: LinkTurn

    private enum Part { case thought(Int), tools([String]) }

    private var parts: [Part] {
        var parts: [Part] = []
        let thoughts = Set(turn.thoughts ?? [])
        for (i, title) in turn.steps.enumerated() {
            if thoughts.contains(i) {
                parts.append(.thought(i))
            } else if case .tools(let before)? = parts.last {
                parts[parts.count - 1] = .tools(before + [title])
            } else {
                parts.append(.tools([title]))
            }
        }
        return parts
    }

    var body: some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .thought(let i): ThoughtLine(title: turn.steps[i], text: turn.reasoning[i])
            case .tools(let titles): StepsLine(steps: titles)
            }
        }
    }
}

/// One thinking phase, folded: "Thought for 3s ›". Tap to read what it thought (when this device has it: a visiting
/// Imp's home sends only the line).
private struct ThoughtLine: View {
    var title: String
    var text: String?
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Button { withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { open.toggle() } } label: {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "brain").font(.icon(.small))
                    Text(title).lineLimit(1)
                    if text != nil {
                        Image(systemName: "chevron.right").font(.icon(.tiny, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(Typeface.small.weight(.medium))
                .foregroundStyle(Tone.muted)
                .frame(minHeight: Sizing.hit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(text == nil)
            if open, let text {
                ScrollView {
                    Text(text)
                        .font(Typeface.small)
                        .foregroundStyle(Tone.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Sizing.thinkingHeight * 3)
                .padding(.leading, Spacing.large)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Spacing.small)
    }
}

/// What the model thinks as it streams in: dim, in a block of fixed height with the newest words at the bottom.
private struct LiveThinking: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typeface.small)
            .foregroundStyle(Tone.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: Sizing.thinkingHeight, maxHeight: Sizing.thinkingHeight, alignment: .bottomLeading)
            .clipped()
            .padding(.leading, Spacing.large)
            .accessibilityLabel(Text(text))
    }
}

/// The tools it used, folded into one line ("Ran 3 tools ›"). Tap to list them.
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
                .transition(.opacity)
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
            if !work.reasoning.isEmpty { LiveThinking(text: work.reasoning) }
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
