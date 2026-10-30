import ImpKit
import SwiftUI

/// An Imp's chat. The Mac does the thinking; this shows the turns it sends and sends what you type.
struct ChatSheet: View {
    let client: LinkClient
    let impID: UUID
    @State private var text = ""
    @FocusState private var focused: Bool

    private var imp: LinkImp? { client.imps.first { $0.id == impID } }
    private var turns: [LinkTurn] { client.chats[impID] ?? [] }
    private var work: LinkWork? { client.work[impID] }

    var body: some View {
        VStack(spacing: 0) {
            if let imp {
                header(imp)
                Divider().overlay(Dungeon.cardEdge)
                transcript(imp)
                composer
            } else {
                // The Imp went back to the Mac while the chat was open.
                ContentUnavailableView("This Imp is back on your Mac", systemImage: "macbook")
                    .foregroundStyle(Dungeon.muted)
            }
        }
        .background(Dungeon.deep)
    }

    // MARK: Header

    private func header(_ imp: LinkImp) -> some View {
        HStack(spacing: 12) {
            LiveImp(imp: imp, mood: mood).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(imp.name).font(.system(.headline, design: .rounded)).foregroundStyle(Dungeon.cream)
                Text(status)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                client.newChat(impID)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 38, height: 38)
                    .background(Dungeon.card, in: Circle())
            }
            .disabled(!client.isConnected)
            .accessibilityLabel("New Chat")
        }
        .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 10)
    }

    private var mood: Mood {
        if !client.isConnected { return .sleepy }
        if let m = client.moods[impID] { return m }
        return work != nil ? .working : .idle
    }

    private var status: String {
        if !client.isConnected { return String(localized: "Your Mac isn't around") }
        if let work { return work.status ?? String(localized: "Thinking…") }
        return String(localized: "Ready")
    }

    // MARK: Transcript

    private func transcript(_ imp: LinkImp) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if turns.isEmpty && work == nil { emptyState }
                    ForEach(turns) { turn in TurnView(turn: turn, name: imp.name) }
                    if let work { LiveTurn(work: work, name: imp.name) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { withAnimation { proxy.scrollTo("end") } }
            .onChange(of: work?.partial) { proxy.scrollTo("end") }
            .onChange(of: focused) { _, on in if on { withAnimation { proxy.scrollTo("end") } } }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 30, weight: .light)).foregroundStyle(Dungeon.ember)
            Text("Ask me anything — I work on your Mac. I can message the Imps on your Mac too.")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28).padding(.horizontal, 12)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if !client.others.isEmpty && text.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(client.others) { other in
                            Button { text = String(localized: "Ask \(other.name) to "); focused = true } label: {
                                Text(other.name)
                                    .font(.system(.footnote, design: .rounded, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Dungeon.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Dungeon.cream)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if !client.isConnected {
                Text("Your Mac isn't around. Chats resume when it is.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Dungeon.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Dungeon.cardEdge))
                if work != nil {
                    Button { client.stop(impID) } label: { glyph("stop.fill") }
                        .accessibilityLabel("Stop")
                } else {
                    Button(action: send) { glyph("arrow.up") }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 16)
            .disabled(!client.isConnected)
            .opacity(client.isConnected ? 1 : 0.5)
        }
        .padding(.top, 8).padding(.bottom, 10)
        .background(Dungeon.deep.opacity(0.95))
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Dungeon.deep)
            .frame(width: 40, height: 40)
            .background(Circle().fill(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom)))
    }

    private func send() {
        client.ask(impID, text)
        text = ""
    }
}

// MARK: - Turns

private func markdown(_ s: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let a = try? AttributedString(markdown: s, options: options) { return Text(a) }
    return Text(s)
}

private struct Bubble: View {
    var text: String
    var mine: Bool
    var failed = false

    var body: some View {
        markdown(text)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(mine ? Dungeon.deep : Dungeon.cream)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if !mine { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(failed ? Color.red.opacity(0.4) : Dungeon.cardEdge) }
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
            .padding(mine ? .leading : .trailing, 44)
    }

    private var fill: AnyShapeStyle {
        if mine { return AnyShapeStyle(LinearGradient(colors: [Dungeon.flame, Dungeon.ember], startPoint: .top, endPoint: .bottom)) }
        if failed { return AnyShapeStyle(Color.red.opacity(0.18)) }
        return AnyShapeStyle(Dungeon.card)
    }
}

private struct TurnView: View {
    var turn: LinkTurn
    var name: String

    var body: some View {
        VStack(spacing: 6) {
            if let from = turn.from {
                Text("from \(from)")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Bubble(text: turn.request, mine: false)
            } else {
                Bubble(text: turn.request, mine: true)
            }
            if !turn.steps.isEmpty {
                Text(stepsLine)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
            }
            Bubble(text: turn.reply, mine: false, failed: turn.failed)
        }
    }

    private var stepsLine: String {
        turn.steps.count == 1 ? turn.steps[0] : String(localized: "Ran \(turn.steps.count) tools")
    }
}

/// What the Imp is working on right now: your message, its step, the answer as it streams in.
private struct LiveTurn: View {
    var work: LinkWork
    var name: String

    var body: some View {
        VStack(spacing: 6) {
            Bubble(text: work.request, mine: true)
            if let status = work.status {
                Text(status)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
            }
            if work.partial.isEmpty {
                TypingDots()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Bubble(text: work.partial, mine: false)
                    TypingDots().padding(.leading, 8)
                }
            }
        }
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Dungeon.muted).frame(width: 7, height: 7)
                        .opacity(0.4 + 0.6 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Dungeon.card, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
