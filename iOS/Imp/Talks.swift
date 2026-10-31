import ImpKit
import SwiftUI

/// What one Imp said with other Imps: the exchanges its own chats hold, the ones the pocket Imps
/// here hold, and the ones the Mac's chats hold. They overlap, and `TalkLog` counts each once.
@MainActor
enum Talks {
    static func threads(of id: UUID, client: LinkClient, pocket: PocketRuntime) -> [TalkThread] {
        TalkLog.threads(of: id, from: pocket.talkLines + (client.talkLines[id] ?? []))
    }
}

/// An Imp's talks, read-only: one row per Imp it talked with, and a tap opens the whole conversation.
/// What's on this phone shows at once; the Mac's join when it answers (an older Mac never does).
struct TalksSheet: View {
    let client: LinkClient
    let pocket: PocketRuntime
    let impID: UUID

    private var threads: [TalkThread] { Talks.threads(of: impID, client: client, pocket: pocket) }
    private var name: String { pocket.imp(impID)?.name ?? client.imp(impID)?.name ?? "" }

    var body: some View {
        NavigationStack {
            let threads = threads
            ScrollView {
                if threads.isEmpty {
                    ContentUnavailableView("No talks yet", systemImage: "bubble.left.and.bubble.right")
                        .foregroundStyle(Dungeon.muted)
                        .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(threads) { thread in
                            NavigationLink(value: thread.peer.id) { TalkRow(thread: thread) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
            .background(Dungeon.deep)
            .navigationTitle(name.isEmpty ? String(localized: "Talks") : String(localized: "\(name)'s talks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: UUID.self) { peer in
                TalkConversation(client: client, pocket: pocket, impID: impID, peerID: peer)
            }
        }
        .task { client.requestTalks(impID) }
    }
}

private struct TalkRow: View {
    var thread: TalkThread

    var body: some View {
        let last = thread.lines.last
        HStack(spacing: 12) {
            Circle().fill(Color.imp(thread.peer.hue)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.peer.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(Dungeon.cream)
                if let last {
                    Text(last.failed ? last.question : last.reply)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Dungeon.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(thread.updated, format: .relative(presentation: .named))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Dungeon.muted)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Dungeon.muted)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Dungeon.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Dungeon.cardEdge))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One talk, read like a messenger: the question from the one who asked, the answer from the other.
private struct TalkConversation: View {
    let client: LinkClient
    let pocket: PocketRuntime
    let impID: UUID
    let peerID: UUID

    private var thread: TalkThread? { Talks.threads(of: impID, client: client, pocket: pocket).first { $0.peer.id == peerID } }

    var body: some View {
        let lines = thread?.lines ?? []
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    if i == 0 || !Calendar.current.isDate(lines[i - 1].date, inSameDayAs: line.date) {
                        Text(Self.day(line.date))
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Dungeon.muted)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Dungeon.card, in: Capsule())
                            .padding(.top, 4)
                    }
                    Exchange(line: line, client: client)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
        }
        .defaultScrollAnchor(.bottom)
        .background(Dungeon.deep)
        .navigationTitle(thread?.peer.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
    var client: LinkClient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Chip(who: line.asker)
                Text(Inline.text(line.question))
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Dungeon.cream)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.imp(line.asker.hue).opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            .padding(.trailing, 36)
            VStack(alignment: .leading, spacing: 5) {
                Chip(who: line.answerer)
                if line.failed {
                    HStack(spacing: 6) {
                        Text("Couldn't answer")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Dungeon.cream)
                        if !line.reply.isEmpty { IssueBadge(text: line.reply) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.red.opacity(0.35)))
                } else {
                    ReplyBlocks(text: line.reply, imp: LinkImp(id: line.answerer.id, name: line.answerer.name, hue: line.answerer.hue, scale: 1, traits: .plain),
                                client: client)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Dungeon.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Dungeon.cardEdge))
                }
            }
            .padding(.leading, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An Imp's name with a dot in its colour.
private struct Chip: View {
    var who: ChatTurn.Sender

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.imp(who.hue)).frame(width: 7, height: 7)
            Text(who.name)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(Color.imp(who.hue)).brightness(0.18)
        }
        .padding(.leading, 6)
    }
}
