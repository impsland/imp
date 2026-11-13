import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// What the Imp is sent of the chat you're in, the chat itself (recap it when it's grown long, or
/// start a new one), and every saved chat: carry on in one, save it as a file, bring one in from a
/// file, or delete it. Starting a new chat never loses the old one: it's right here in the list.
struct MemoryCard: View {
    let model: AppModel
    @Binding var imp: ImpProfile
    /// The chats of an Imp at home (one that's out has them live, in its `ImpModel`).
    @State private var stored: ChatHistory?
    @State private var showsAll = false
    @State private var deleting: ChatSummary?
    @State private var deletingTalk: TalkThread?
    @Environment(\.postNotice) private var postNotice
    /// New Chat asks first: a second click within a few seconds does it.
    @State private var asking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Talks with other Imps, read from every Imp's chats (nil until loaded).
    @State private var talks: [TalkThread] = []

    private var name: String { imp.callName }
    private var live: ImpModel? { model.imp(imp.id) }
    private var history: ChatHistory? { live?.history ?? stored }
    /// Chats listed before "Show all".
    private static let shortList = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            memoryCard
            chatList
            if !talks.isEmpty {
                talkList
            }
        }
        .task(id: live == nil) { reloadStored() }
        .task(id: history?.chats.first?.updated) { talks = TalkLog.threads(of: imp.id, from: await model.talkLines()) }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { chat in
            Button("Delete", role: .destructive) { delete(chat.id) }
        } message: { _ in
            Text("What was said and \(name)'s memory of it are gone for good. Save it as a file first to keep it.")
        }
        .confirmationDialog("Delete the talk with \(deletingTalk?.peer.name ?? "")?", isPresented: Binding(get: { deletingTalk != nil }, set: { if !$0 { deletingTalk = nil } }),
                            presenting: deletingTalk) { talk in
            Button("Delete", role: .destructive) { deleteTalk(talk) }
        } message: { talk in
            Text("\(name)'s side of the talk and its memory of it are gone for good. \(talk.peer.name) keeps its own.")
        }
    }

    private var memoryCard: some View {
        Card("Memory", icon: "brain",
             info: "Every chat is saved. Carry on in an older one, save it or bring one in.",
             accessory: { newChatButton }) {
            Row("memory.sends.title", icon: "clock.arrow.circlepath", info: "memory.sends.info") {
                ImpPicker("memory.sends.title", selection: Binding(get: { imp.memoryExchanges },
                                                                   set: { imp.exchangesSent = $0 == ChatMemory.noLimit ? nil : $0 }),
                          options: [ChatMemory.noLimit] + ChatMemory.choices
                            + (ChatMemory.choices.contains(imp.memoryExchanges) || imp.memoryExchanges == ChatMemory.noLimit ? [] : [imp.memoryExchanges])) {
                    $0 == ChatMemory.noLimit ? String(localized: "memory.no_limit") : words("memory.last", $0)
                }
            }
            .settingAnchor(.brainSends)
            Row("memory.tools.title", icon: "wrench.and.screwdriver", info: "memory.tools.info") {
                Toggle(String(""), isOn: Binding(get: { imp.remembersToolCalls }, set: { imp.sendsToolCalls = $0 ? nil : false }))
                    .labelsHidden().toggleStyle(.impSwitchBare)
            }
            .settingAnchor(.brainTools)
            Row("memory.new_chat.title", icon: "plus.bubble", info: "memory.new_chat.info") {
                ImpPicker("memory.new_chat.title", selection: Binding(get: { imp.newChatAt },
                                                                      set: { imp.newChatAtTokens = $0 == ImpProfile.newChatDefault ? nil : $0 }),
                          options: ImpProfile.newChatChoices) {
                    $0 >= 1_000_000 ? words("memory.size.m", $0 / 1_000_000) : words("memory.size.k", $0 / 1000)
                }
            }
            .settingAnchor(.brainNewChat)
            if let live {
                CurrentChat(imp: live, profile: imp)
            } else {
                Row("Current chat", icon: "bubble.left.and.text.bubble.right", info: "Let \(name) out to chat or recap.") {
                    StatusText(text: "At home")
                }
                .settingAnchor(.brainCurrentChat)
            }
        }
    }

    /// New Chat sits in the card's header. The chat you're in stays in the list below.
    @ViewBuilder private var newChatButton: some View {
        if let live {
            Button { confirmNew(live) } label: {
                FitLabel(asking ? "Start new?" : "New Chat", systemImage: "plus.bubble")
            }
            .buttonStyle(.imp(.secondary, small: true))
            .disabled(live.history.isEmpty)
            .help("Start a fresh chat. This one stays in the list below.")
        }
    }

    private func confirmNew(_ live: ImpModel) {
        if asking { asking = false; live.newChat(); return }
        asking = true
        Task { try? await Task.sleep(for: .seconds(3)); asking = false }
    }

    // MARK: Saved chats

    @ViewBuilder private var chatList: some View {
        // Only chats with you: talks between Imps are listed once, under Talks.
        let chats = history?.chatsWithYou ?? []
        PanelList("Chats", icon: "bubble.left.and.bubble.right.fill",
                  info: "Every chat with \(name), newest first. Continue one to pick up where you left off.",
                  accessory: {
            HStack(spacing: Spacing.small) {
                if !chats.isEmpty {
                    Text(verbatim: "\(chats.count)").font(Typeface.small.weight(.semibold)).foregroundStyle(Tone.muted)
                }
                Button { importChat() } label: { FitLabel("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.imp(.quiet, small: true))
                    .help("Bring in a chat saved from Imp, to carry on with \(name)")
            }
        }) {
            if chats.isEmpty {
                StatusText(text: "No chats yet.").padding(.horizontal, Spacing.small)
            } else {
                VStack(spacing: Spacing.snug) {
                    let shown = showsAll ? chats : Array(chats.prefix(Self.shortList))
                    ForEach(shown) { chat in
                        ChatRow(chat: chat, isCurrent: chat.id == history?.current.id, canContinue: live != nil, name: name,
                                read: { HomeWindow.shared.showChat(model, imp: imp.id, chat: chat.id) }, open: { open(chat.id) }, export: { export(chat) }, delete: { deleting = chat })
                    }
                }
                if chats.count > Self.shortList {
                    Button(showsAll ? "Show fewer" : "Show all \(chats.count)") {
                        withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { showsAll.toggle() }
                    }
                    .buttonStyle(.quiet)
                }
            }
        }
    }

    /// What \(name) and each other Imp said to each other, both ways (their halves are in both Imps' chats).
    /// This is the only place a conversation between Imps is listed: the chats above are with you.
    private var talkList: some View {
        PanelList("Talks", icon: "person.2.fill", info: "What \(name) and other Imps said to each other.",
                  accessory: { Text(verbatim: "\(talks.count)").font(Typeface.small.weight(.semibold)).foregroundStyle(Tone.muted) }) {
            VStack(spacing: Spacing.snug) {
                ForEach(talks) { talk in
                    TalkRow(talk: talk, open: { HomeWindow.shared.showTalk(model, imp: imp.id, peer: talk.peer.id) },
                            delete: { deletingTalk = talk })
                }
            }
        }
    }

    /// Deletes this Imp's side of a talk: its saved chats with that Imp.
    private func deleteTalk(_ talk: TalkThread) {
        deletingTalk = nil
        for chat in history?.chats ?? [] where chat.peer == talk.peer.id { delete(chat.id) }
        talks.removeAll { $0.id == talk.id }
    }

    private func reloadStored() {
        // Renders and tests (nothing persists) never read the user's real chats.
        stored = live == nil ? (model.persists ? ChatHistory(folder: ChatHistory.folder(for: imp.id)) : model.sampleChats[imp.id] ?? ChatHistory(folder: nil)) : nil
    }

    /// Carries on in a chat: it becomes the current one, and opens beside the Imp.
    private func open(_ id: UUID) {
        guard let live else { return }
        live.switchChat(to: id)
        live.openChat()
    }

    private func delete(_ id: UUID) {
        deleting = nil
        if let live { live.deleteChat(id) } else { stored?.delete(id) }
    }

    private func say(_ text: String, ok: Bool) {
        postNotice(ok ? .success(text) : .error(text))
    }

    private func export(_ summary: ChatSummary) {
        guard let chat = history?.chat(summary.id), ChatFile.canExport(chat) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = ChatFile.fileName(chat)
        panel.canCreateDirectories = true
        panel.message = String(localized: "Save this chat as a file. Import it later to carry on, with \(name) or another Imp, on this Mac or another.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        do {
            try Data(ChatFile.text(chat, imp: imp.name, app: version).utf8).write(to: url, options: .atomic)
            say(String(localized: "Saved"), ok: true)
        } catch {
            say(String(localized: "Couldn't save: \(error.localizedDescription)"), ok: false)
        }
    }

    private func importChat() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose chats saved from Imp (.json)")
        guard panel.runModal() == .OK else { return }
        var added = 0
        var failure: String?
        for url in panel.urls {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes[.size] as? Int, size > ChatFile.maxBytes { throw ChatFile.Failure.tooLarge }
                let chat = try ChatFile.read(String(decoding: try Data(contentsOf: url), as: UTF8.self))
                if let live { live.importChat(chat) } else { stored?.adopt(chat) }
                added += 1
            } catch {
                failure = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let failure { say(failure, ok: false) }
        else if added > 0 { say(String(localized: "\(added) chats added"), ok: true) }
    }
}

/// One chat or talk in a list.
private struct MemoryRow<Actions: View>: View {
    let symbol: String
    let tint: Color
    let lit: Bool
    let title: String
    /// Said in place of the date, like "Current".
    var label: LocalizedStringKey?
    let date: Date
    let count: LocalizedStringKey
    /// A click on the row reads it.
    let read: () -> Void
    @ViewBuilder var actions: Actions
    @State private var hover = false

    /// The title has the whole width of the row. Under it: when and how much, with the actions on
    /// the trailing edge. Nothing is cut short while the panel has room.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button(action: read) {
                HStack(alignment: .top, spacing: Spacing.cozy) {
                    IconTile(systemName: symbol)
                        .environment(\.impTint, lit ? tint : Tone.muted)
                    Text(verbatim: title).font(Typeface.body).foregroundStyle(Tone.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: Sizing.iconTile, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: Spacing.tight) {
                Group {
                    if let label { Text(label).foregroundStyle(LegibleTint(tint)) } else {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    Text(verbatim: "·")
                    Text(count)
                }
                .font(Typeface.small).foregroundStyle(Tone.muted)
                .lineLimit(1).fixedSize()
                Spacer(minLength: Spacing.small)
                HStack(spacing: 0) { actions }
            }
            .padding(.leading, Sizing.iconTile + Spacing.cozy)
        }
        .pebble(hover: hover)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
        .accessibilityElement(children: .contain)
    }
}

/// A saved chat in the list: its title and when, then Continue, Read, Save as File and Delete.
private struct ChatRow: View {
    let chat: ChatSummary
    let isCurrent: Bool
    let canContinue: Bool
    let name: String
    /// Reads the chat as bubbles or JSON.
    let read: () -> Void
    let open: () -> Void
    let export: () -> Void
    let delete: () -> Void
    @Environment(\.impTint) private var tint

    var body: some View {
        MemoryRow(symbol: isCurrent ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.bubble.right",
                  tint: tint, lit: isCurrent,
                  title: chat.title.isEmpty ? String(localized: "Chat") : chat.title,
                  label: isCurrent ? "Current" : nil,
                  date: chat.updated, count: "\(chat.turns) messages", read: read) {
            if !isCurrent {
                HoverIconButton(systemName: "arrow.uturn.forward", help: canContinue ? "Make this the chat you're in and open it" : "Let \(name) out to continue this chat",
                                tint: tint, action: open)
                    .disabled(!canContinue)
            }
            HoverIconButton(systemName: "square.and.arrow.up", help: "Save as a file", action: export)
            HoverIconButton(systemName: "trash", help: "Delete this chat", tint: Tone.danger, action: delete)
        }
        .contextMenu {
            Section {
                Button("Read") { read() }
                if !isCurrent { Button("Continue") { open() }.disabled(!canContinue) }
                Button("Save as File…") { export() }
            }
            Button("Delete…", role: .destructive) { delete() }
        }
    }
}

/// A talk with another Imp in the list: who, when, how much, and Read.
struct TalkRow: View {
    let talk: TalkThread
    let open: () -> Void
    var delete: (() -> Void)?

    var body: some View {
        MemoryRow(symbol: "person.2", tint: Color.imp(talk.peer.hue), lit: true, title: talk.peer.name,
                  date: talk.updated, count: "\(talk.lines.count) exchanges", read: open) {
            if let delete { HoverIconButton(systemName: "trash", help: "Delete this Imp's side of the talk", tint: Tone.danger, action: delete) }
        }
        .contextMenu {
            Button("Read") { open() }
            if let delete { Button("Delete…", role: .destructive) { delete() } }
        }
    }
}

/// The chat in progress: its name and size, with Recap and Open at the trailing edge. (New Chat is in
/// the card's header.)
private struct CurrentChat: View {
    let imp: ImpModel
    let profile: ImpProfile
    /// Recap asks first: a second click within a few seconds does it.
    @State private var asking = false
    @Environment(\.postNotice) private var postNotice

    var body: some View {
        let chat = imp.history.current
        let memory = chat.memory
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.cozy) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.snug) {
                        (chat.title.isEmpty ? Text("New chat") : Text(verbatim: chat.title))
                            .font(Typeface.body.weight(.semibold)).foregroundStyle(Tone.text)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(details(memory)).font(Typeface.small).foregroundStyle(Tone.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { confirmRecap() } label: {
                    StatefulLabel(asking ? "Recap now?" : "Recap", symbol: "rectangle.compress.vertical",
                                  state: imp.isRecapping ? .working : .idle)
                }
                .buttonStyle(.imp(.secondary, small: true))
                .disabled(!imp.canRecap)
                .onChange(of: imp.recapError) { _, error in if let error { postNotice(.error(String(localized: "Couldn't recap: \(error)"))) } }
                HoverIconButton(systemName: "bubble.left.and.bubble.right.fill", help: "Open the chat beside \(profile.callName)") { imp.openChat() }
                InfoTip("\(profile.callName) keeps a short recap and the last exchange. The whole chat stays to read.")
            }
        }
    }

    /// First click asks (for a few seconds), the second does it.
    private func confirmRecap() {
        if asking { asking = false; imp.recapChat(); return }
        asking = true
        Task { try? await Task.sleep(for: .seconds(3)); asking = false }
    }

    private func details(_ memory: ChatMemory) -> String {
        guard !memory.isEmpty else { return String(localized: "Nothing said yet") }
        let n = memory.exchangeCount
        let tokens = memory.estimatedTokens(exchanges: profile.memoryExchanges, tools: profile.remembersToolCalls)
        let size = tokens.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        return memory.recap == nil
            ? String(localized: "\(n) exchanges · about \(size) tokens sent")
            : String(localized: "\(n) exchanges and a recap · about \(size) tokens sent")
    }
}
