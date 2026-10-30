import ImpKit
import QuickLook
import SwiftUI

/// An Imp's chat. It shows the turns its source has and sends what you type: the Mac does the
/// thinking for its Imps, this iPhone for the pocket ones.
/// Replies are drawn from their Markdown like the Mac's bubble: text, lists, code and tables, and
/// the pictures, voices, videos and files they show, fetched from the Mac (`LinkFileStore`).
struct ChatSheet: View {
    /// Where files in replies come from (the Mac).
    let client: LinkClient
    let source: any ChatSource
    let impID: UUID
    /// Opens the Imp's settings. Only the Imps hatched on this iPhone have any.
    var edit: (() -> Void)?
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var confirmingNewChat = false
    /// A file to look at full screen (Quick Look).
    @State private var preview: URL?
    @State private var problem: String?
    /// Voices in replies that arrive after this play on their own (older ones wait for a tap).
    @State private var openedAt = Date()

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
                transcript(imp)
                composer(imp)
            } else {
                // The Imp went back to the Mac while the chat was open.
                ContentUnavailableView("This Imp is back on your Mac", systemImage: "macbook")
                    .foregroundStyle(Dungeon.muted)
            }
        }
        .background(Dungeon.deep)
        .environment(\.openURL, OpenURLAction { url in open(url) })
        .quickLookPreview($preview)
        .overlay(alignment: .top) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.cream)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: problem) {
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { self.problem = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: problem)
        .confirmationDialog("Start a new chat?", isPresented: $confirmingNewChat, titleVisibility: .visible) {
            Button("New Chat") {
                source.newChat(impID)
                openedAt = Date()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } message: {
            if let imp { Text(source.newChatNote(imp)) }
        }
    }

    // MARK: Header

    private func header(_ imp: LinkImp) -> some View {
        HStack(spacing: 12) {
            LiveImp(imp: imp, mood: mood).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(imp.name).font(.system(.headline, design: .rounded)).foregroundStyle(Dungeon.cream)
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Dungeon.muted)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            if let edit {
                Menu {
                    Button(action: edit) { Label("Edit", systemImage: "slider.horizontal.3") }
                    Button { confirmingNewChat = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
                        .disabled(!canStartOver)
                } label: {
                    roundGlyph("ellipsis")
                }
                .accessibilityLabel("More")
            } else {
                Button { confirmingNewChat = true } label: { roundGlyph("square.and.pencil") }
                    .disabled(!canStartOver)
                    .opacity(canStartOver ? 1 : 0.4)
                    .accessibilityLabel("New Chat")
            }
        }
        .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 12)
        .background(alignment: .bottom) { Rectangle().fill(Dungeon.cardEdge).frame(height: 1) }
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private func roundGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Dungeon.cream)
            .frame(width: 38, height: 38)
            .background(Dungeon.card, in: Circle())
            .overlay(Circle().strokeBorder(Dungeon.cardEdge))
    }

    private var mood: Mood {
        if availability != .ready { return .sleepy }
        if let m = source.mood(impID) { return m }
        return work != nil ? .working : .idle
    }

    private var status: String {
        switch availability {
        case .offline: return String(localized: "Your Mac isn't around")
        case .noBrain: return String(localized: "No brain yet")
        case .ready: break
        }
        if let work { return work.status ?? (work.partial.isEmpty ? String(localized: "Thinking…") : String(localized: "Answering…")) }
        if let w = source.working(impID), let from = w.from { return String(localized: "Answering \(from)…") }
        return source.restingStatus
    }

    private var statusColor: Color {
        if availability != .ready { return Dungeon.muted }
        return source.working(impID) != nil ? Dungeon.flame : Dungeon.good
    }

    // MARK: Transcript

    private func transcript(_ imp: LinkImp) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if turns.isEmpty && work == nil { emptyState(imp) }
                    ForEach(Array(turns.enumerated()), id: \.element.id) { i, turn in
                        if let label = Self.separator(turn.date, after: i > 0 ? turns[i - 1].date : nil) {
                            DaySeparator(text: label)
                        }
                        TurnView(turn: turn, imp: imp, client: client, fresh: turn.date > openedAt,
                                 retry: availability == .ready ? { source.ask(impID, turn.request) } : nil)
                    }
                    if let work { LiveTurn(work: work, imp: imp, client: client) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14).padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.last?.id) { _, _ in
                withAnimation(.spring(duration: 0.4)) { proxy.scrollTo("end", anchor: .bottom) }
                if turns.last?.date ?? .distantPast > openedAt {
                    UINotificationFeedbackGenerator().notificationOccurred(turns.last?.failed == true ? .error : .success)
                }
            }
            .onChange(of: work?.partial) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: work == nil) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: focused) { _, on in if on { withAnimation { proxy.scrollTo("end", anchor: .bottom) } } }
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
        return VStack(spacing: 10) {
            Image(systemName: availability == .noBrain ? "moon.zzz" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Dungeon.ember)
            Text(intro.title)
                .font(.system(.headline, design: .rounded)).foregroundStyle(Dungeon.cream)
            Text(intro.text)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 36).padding(.horizontal, 18)
    }

    // MARK: Composer

    private func composer(_ imp: LinkImp) -> some View {
        VStack(spacing: 8) {
            let peers = availability == .ready ? source.peers(impID) : []
            if !peers.isEmpty && text.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(peers) { other in
                            Button {
                                text = String(localized: "Ask \(other.name) to ")
                                focused = true
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Color.imp(other.hue)).frame(width: 8, height: 8)
                                    Text(other.name).font(.system(.footnote, design: .rounded, weight: .medium))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Dungeon.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Dungeon.cream)
                            .accessibilityHint("Starts a message asking \(other.name) to do something.")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            switch availability {
            case .offline:
                Label("Your Mac isn't around. Chats resume when it is.", systemImage: "wifi.slash")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            case .noBrain:
                Button { edit?() } label: { Label("Give it a brain", systemImage: "sparkles") }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Dungeon.flame)
            case .ready:
                EmptyView()
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(imp.name)", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .foregroundStyle(Dungeon.cream)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Dungeon.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(focused ? Dungeon.ember.opacity(0.6) : Dungeon.cardEdge))
                if work != nil && trimmed.isEmpty {
                    Button { source.stop(impID); UIImpactFeedbackGenerator(style: .medium).impactOccurred() } label: { glyph("stop.fill") }
                        .accessibilityLabel("Stop")
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(action: send) { glyph("arrow.up") }
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.45 : 1)
                        .accessibilityLabel("Send")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: work == nil)
            .padding(.horizontal, 14)
            .disabled(availability != .ready)
            .opacity(availability == .ready ? 1 : 0.5)
        }
        .padding(.top, 10).padding(.bottom, 10)
        .background(alignment: .top) { Rectangle().fill(Dungeon.cardEdge).frame(height: 1) }
        .background(Dungeon.deep)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Dungeon.deep)
            .frame(width: 40, height: 40)
            .background(Circle().fill(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom)))
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
            do { preview = try await client.files.file(imp: impID, ref: ref) }
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
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(Dungeon.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Dungeon.card, in: Capsule())
            .padding(.top, 4)
    }
}

/// What you asked: on the right, in ember.
private struct AskBubble: View {
    var text: String
    var retry: (() -> Void)?

    var body: some View {
        Text(Inline.text(text))
            .font(.system(.body, design: .rounded))
            .foregroundStyle(Dungeon.deep)
            .tint(Dungeon.deep)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                if let retry { Button(action: retry) { Label("Ask Again", systemImage: "arrow.clockwise") } }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }
}

private struct TurnView: View {
    var turn: LinkTurn
    var imp: LinkImp
    var client: LinkClient
    /// Arrived while the chat was open (its voice may play on its own).
    var fresh: Bool
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            AskBubble(text: turn.request, retry: retry)
            if !turn.steps.isEmpty { StepsLine(steps: turn.steps) }
            ReplyCard(text: turn.reply, imp: imp, client: client, failed: turn.failed, autoplay: fresh, retry: turn.failed ? retry : nil)
        }
    }
}

/// The tools it used, folded into one line ("Ran 3 tools ›"); tap to list them.
private struct StepsLine: View {
    var steps: [String]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape.2.fill").font(.system(size: 10))
                    Text(steps.count == 1 ? steps[0] : String(localized: "Ran \(steps.count) tools"))
                        .lineLimit(1)
                    if steps.count > 1 {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.muted)
            }
            .buttonStyle(.plain)
            .disabled(steps.count < 2)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "checkmark").labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }
}

/// The Imp's answer: its Markdown, drawn block by block, in a card on the left.
private struct ReplyCard: View {
    var text: String
    var imp: LinkImp
    var client: LinkClient
    var failed = false
    var streaming = false
    var autoplay = false
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if failed {
                Label("Couldn't answer", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
            }
            ReplyBlocks(text: text, imp: imp, client: client, autoplay: autoplay)
            if streaming { TypingDots(compact: true) }
            if let retry {
                Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise") }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Dungeon.flame)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(failed ? AnyShapeStyle(Color.red.opacity(0.14)) : AnyShapeStyle(Dungeon.card),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(failed ? Color.red.opacity(0.35) : Dungeon.cardEdge))
        .contextMenu {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 28)
    }
}

/// The answer being written: your message, what it's doing, the words so far.
private struct LiveTurn: View {
    var work: LinkWork
    var imp: LinkImp
    var client: LinkClient

    var body: some View {
        VStack(spacing: 8) {
            AskBubble(text: work.request)
            if let status = work.status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).tint(Dungeon.muted)
                    Text(status).lineLimit(1)
                }
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
            }
            if work.partial.isEmpty {
                TypingDots().frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ReplyCard(text: work.partial, imp: imp, client: client, streaming: true)
            }
        }
    }
}

struct TypingDots: View {
    var compact = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Dungeon.muted).frame(width: compact ? 5 : 7, height: compact ? 5 : 7)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, compact ? 0 : 14).padding(.vertical, compact ? 2 : 12)
            .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(Dungeon.card), in: Capsule())
        }
        .accessibilityLabel("Writing")
    }
}
