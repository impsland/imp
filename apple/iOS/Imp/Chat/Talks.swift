import ImpDesign
import ImpKit
import SwiftUI

/// What one Imp said with other Imps: the exchanges its own chats hold, the ones the pocket Imps
/// here hold, and the ones the Mac's chats hold. They overlap, and `TalkLog` counts each once.
@MainActor
enum Talks {
    /// An exchange is kept by the Imp that answered it, so what an Imp here asked a visitor is in the
    /// visitor's home: every visitor's lines count, not only this Imp's own.
    static func threads(of id: UUID, hub: LinkHub, pocket: PocketRuntime) -> [TalkThread] {
        TalkLog.threads(of: id, from: pocket.talkLines + hub.talkLines.values.joined())
    }

    /// Asks the homes that may hold `id`'s talks for them: its own home when it visits, else the homes
    /// of the Imps visiting here (they answered what it asked them).
    static func refresh(_ id: UUID, hub: LinkHub) {
        if hub.visit(id) != nil { return hub.requestTalks(id) }
        for visitor in hub.visitors { hub.requestTalks(visitor.id) }
    }
}

/// An Imp's talks, read-only, as the second side of its sheet: one row per Imp it talked with, and a
/// tap opens the whole conversation in place, with one way back. What's on this phone shows at once;
/// the Mac's join when it answers (an older Mac never does).
struct TalksPane: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    let impID: UUID
    /// The Imp whose conversation is open, or nil for the list.
    @State private var peer: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var threads: [TalkThread] { Talks.threads(of: impID, hub: hub, pocket: pocket) }

    var body: some View {
        let threads = threads
        Group {
            if let thread = threads.first(where: { $0.peer.id == peer }) {
                VStack(spacing: 0) {
                    Button { show(nil) } label: {
                        HStack(spacing: Spacing.snug) {
                            Image(systemName: "chevron.left").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.muted)
                            Circle().fill(Color.imp(thread.peer.hue)).frame(width: Spacing.small, height: Spacing.small)
                            Text(thread.peer.name).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1)
                        }
                        .frame(minHeight: Sizing.hit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.back"))
                    .accessibilityValue(Text(thread.peer.name))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.page)
                    TalkConversation(thread: thread, hub: hub, impID: impID)
                }
                .transition(.opacity)
            } else {
                ScrollView {
                    if threads.isEmpty {
                        VStack(spacing: Spacing.cozy) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.icon(.huge, weight: .light)).foregroundStyle(LegibleTint())
                            Text("phone.talks.empty").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.vast).padding(.horizontal, Spacing.page)
                    } else {
                        LazyVStack(spacing: Spacing.small) {
                            ForEach(threads) { thread in
                                Button { show(thread.peer.id) } label: { TalkRow(thread: thread) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.medium)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .impControls()
        .task { Talks.refresh(impID, hub: hub) }
    }

    private func show(_ peer: UUID?) {
        withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { self.peer = peer }
    }
}

private struct TalkRow: View {
    var thread: TalkThread

    var body: some View {
        let last = thread.lines.last
        HStack(spacing: Spacing.medium) {
            Circle().fill(Color.imp(thread.peer.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(thread.peer.name)
                    .font(Typeface.cardTitle)
                    .foregroundStyle(Tone.text)
                if let last {
                    Text(last.failed ? last.question : last.reply)
                        .font(Typeface.caption)
                        .foregroundStyle(Tone.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.small)
            Text(thread.updated, format: .relative(presentation: .named))
                .font(Typeface.small)
                .foregroundStyle(Tone.muted)
            Image(systemName: "chevron.right").font(.icon(.small, weight: .bold)).foregroundStyle(Tone.muted)
        }
        .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.medium)
        .frame(minHeight: Sizing.hit)
        .impCard(radius: Radius.large)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One talk, read like a messenger: the question from the one who asked, the answer from the other.
private struct TalkConversation: View {
    let thread: TalkThread
    let hub: LinkHub
    /// The Imp whose sheet this is.
    let impID: UUID

    var body: some View {
        let lines = thread.lines
        ScrollView {
            LazyVStack(spacing: Spacing.roomy) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    if i == 0 || !Calendar.current.isDate(lines[i - 1].date, inSameDayAs: line.date) {
                        Text(Self.day(line.date))
                            .font(Typeface.small.weight(.semibold))
                            .foregroundStyle(Tone.muted)
                            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.tight)
                            .background(Tone.card, in: Capsule())
                            .padding(.top, Spacing.tight)
                    }
                    Exchange(line: line, hub: hub, impID: impID)
                }
            }
            .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.large)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
    }

    private static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }
}

/// A question and its answer, each under a small chip with the Imp's name in its colour.
private struct Exchange: View {
    var line: TalkLine
    var hub: LinkHub
    /// The Imp whose sheet this is.
    var impID: UUID

    /// Who the files in the answer are fetched through: an Imp this phone holds, as only its holder may ask
    /// its home for them. The sheet's own Imp first, else either of the two talking. Its home sends what the
    /// talk mentions: the links in it say whose file each is (see `DeviceLink.talkLinesForLink`).
    private var via: UUID {
        [impID, line.answerer.id, line.asker.id].first { hub.visit($0) != nil } ?? line.answerer.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Chip(who: line.asker)
                Text(Inline.text(line.question))
                    .font(Typeface.body)
                    .foregroundStyle(Tone.text)
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.cozy)
                    .background(Color.imp(line.asker.hue).opacity(Opacity.tintFill), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                    .textSelection(.enabled)
            }
            .padding(.trailing, Spacing.vast)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Chip(who: line.answerer)
                if line.failed {
                    HStack(spacing: Spacing.snug) {
                        Text("Couldn't answer")
                            .font(Typeface.label)
                            .foregroundStyle(Tone.text)
                        if !line.reply.isEmpty { IssueBadge(text: line.reply) }
                    }
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.snug)
                    .background(Tone.errorBackground, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
                } else {
                    ReplyBlocks(text: line.reply, imp: LinkImp(id: via, name: line.answerer.name, hue: line.answerer.hue, scale: 1, traits: .plain),
                                hub: hub)
                        .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.medium)
                        .impCard(radius: Radius.large)
                }
            }
            .padding(.leading, Spacing.page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An Imp's name with a dot in its colour.
private struct Chip: View {
    var who: ChatTurn.Sender

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Circle().fill(Color.imp(who.hue)).frame(width: Spacing.snug, height: Spacing.snug)
            Text(who.name)
                .font(Typeface.small.weight(.bold))
                // The Imp colour, nudged until it reads on the surface.
                .foregroundStyle(LegibleTint(Color.imp(who.hue), on: .surface))
        }
        .padding(.leading, Spacing.snug)
    }
}
