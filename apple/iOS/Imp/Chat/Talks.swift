import ImpDesign
import ImpKit
import SwiftUI

/// What one Imp said with other Imps: the exchanges its own chats hold, the ones the pocket Imps
/// here hold, and the ones the Mac's chats hold. They overlap, and `TalkLog` counts each once.
@MainActor
enum Talks {
    static func threads(of id: UUID, hub: LinkHub, pocket: PocketRuntime) -> [TalkThread] {
        TalkLog.threads(of: id, from: pocket.talkLines + (hub.talkLines[id] ?? []))
    }
}

/// An Imp's talks, read-only: one row per Imp it talked with, and a tap opens the whole conversation.
/// What's on this phone shows at once; the Mac's join when it answers (an older Mac never does).
struct TalksSheet: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    let impID: UUID

    private var threads: [TalkThread] { Talks.threads(of: impID, hub: hub, pocket: pocket) }
    private var name: String { pocket.imp(impID)?.name ?? hub.imp(impID)?.name ?? "" }

    var body: some View {
        NavigationStack {
            let threads = threads
            ScrollView {
                if threads.isEmpty {
                    ContentUnavailableView("No talks yet", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(Tone.muted)
                        .padding(.top, Spacing.vast)
                } else {
                    LazyVStack(spacing: Spacing.small) {
                        ForEach(threads) { thread in
                            NavigationLink(value: thread.peer.id) { TalkRow(thread: thread) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.medium)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .containerBackground(Tone.surface, for: .navigation)
            .navigationTitle(name.isEmpty ? String(localized: "Talks") : String(localized: "\(name)'s talks"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { peer in
                TalkConversation(hub: hub, pocket: pocket, impID: impID, peerID: peer)
            }
        }
        .impControls(tint: Tone.accent)
        .presentationBackground(Tone.surface)
        .task { hub.requestTalks(impID) }
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
    let hub: LinkHub
    let pocket: PocketRuntime
    let impID: UUID
    let peerID: UUID

    private var thread: TalkThread? { Talks.threads(of: impID, hub: hub, pocket: pocket).first { $0.peer.id == peerID } }

    var body: some View {
        let lines = thread?.lines ?? []
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
                    Exchange(line: line, hub: hub)
                }
            }
            .padding(.horizontal, Spacing.roomy).padding(.vertical, Spacing.large)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        .containerBackground(Tone.surface, for: .navigation)
        .navigationTitle(thread?.peer.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
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
                    ReplyBlocks(text: line.reply, imp: LinkImp(id: line.answerer.id, name: line.answerer.name, hue: line.answerer.hue, scale: 1, traits: .plain),
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
