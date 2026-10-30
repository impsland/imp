import AppKit
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
    @State private var notice: (text: String, ok: Bool)?

    private var name: String { imp.callName }
    private var live: ImpModel? { model.imp(imp.id) }
    private var history: ChatHistory? { live?.history ?? stored }
    /// Chats listed before "Show all".
    private static let shortList = 6

    var body: some View {
        Card("Memory", icon: "brain",
             info: "What \(name) is sent from the chat you're in. Every chat is saved: carry on in an older one, save it as a file, or bring one in.") {
            Row("Tool calls",
                info: "Also sends the tools \(name) used and their results, so it can reuse a file or link. Off is smaller and cheaper.") {
                Toggle(String(""), isOn: Binding(get: { imp.remembersToolCalls }, set: { imp.sendsToolCalls = $0 ? nil : false }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            CardDivider()
            Row("Remembers",
                info: "How many recent exchanges are sent with each message. More remembers more, but each message is bigger, slower and costs more: recap a long chat to keep it small. Older ones stay in the chat to read.") {
                Picker(String(""), selection: Binding(get: { imp.memoryExchanges },
                                              set: { imp.exchangesSent = $0 == ChatMemory.defaultExchanges ? nil : $0 })) {
                    ForEach(ChatMemory.choices, id: \.self) { Text("Last \($0)").tag($0) }
                    if !ChatMemory.choices.contains(imp.memoryExchanges) { Text("Last \(imp.memoryExchanges)").tag(imp.memoryExchanges) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            CardDivider()
            if let live {
                CurrentChat(imp: live, profile: imp)
            } else {
                Row("Current chat", info: "Let \(name) out to chat, recap or start a new chat.") {
                    StatusText(text: "At home")
                }
            }
            CardDivider()
            chatList
        }
        .task(id: live == nil) { reloadStored() }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { chat in
            Button("Delete", role: .destructive) { delete(chat.id) }
        } message: { _ in
            Text("What was said and \(name)'s memory of it are gone for good. Save it as a file first to keep it.")
        }
    }

    // MARK: Saved chats

    @ViewBuilder private var chatList: some View {
        let chats = history?.chats ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Chats").font(.system(size: 13)).lineLimit(1)
                InfoTip("Every chat with \(name), newest first. Continue one to pick up where you left off: \(name) remembers it as it was. Save one as a file to keep it or to carry it on with another Imp or on another Mac.")
                if !chats.isEmpty { Text(verbatim: "\(chats.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Dungeon.muted) }
                Spacer(minLength: 8)
                if let notice {
                    StatusText(verbatim: notice.text, symbol: notice.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                               color: notice.ok ? .green : .orange)
                        .help(notice.text)
                }
                Button { importChat() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.imp(.quiet, small: true))
                    .help("Bring in a chat saved from Imp, to carry on with \(name)")
            }
            if chats.isEmpty {
                StatusText(text: "No chats yet.")
            } else {
                VStack(spacing: 2) {
                    ForEach(showsAll ? chats : Array(chats.prefix(Self.shortList))) { chat in
                        ChatRow(chat: chat, isCurrent: chat.id == history?.current.id, canContinue: live != nil, name: name,
                                open: { open(chat.id) }, export: { export(chat) }, delete: { deleting = chat })
                    }
                }
                if chats.count > Self.shortList {
                    Button(showsAll ? "Show fewer" : "Show all \(chats.count)") {
                        withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.tint)
                }
            }
        }
    }

    private func reloadStored() {
        stored = live == nil ? ChatHistory(folder: ChatHistory.folder(for: imp.id)) : nil
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
        withAnimation { notice = (text, ok) }
        Task { try? await Task.sleep(for: .seconds(4)); withAnimation { if notice?.text == text { notice = nil } } }
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

/// A saved chat in the list: its name and when, then Continue, Save as File and Delete.
private struct ChatRow: View {
    let chat: ChatSummary
    let isCurrent: Bool
    let canContinue: Bool
    let name: String
    let open: () -> Void
    let export: () -> Void
    let delete: () -> Void
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: chat.peer != nil ? "person.2.fill" : (isCurrent ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.bubble.right"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isCurrent ? tint : .secondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(isCurrent ? 0.18 : 0.06)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: chat.title.isEmpty ? String(localized: "Chat") : chat.title)
                        .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if isCurrent { Badge("Current", symbol: "circle.fill", color: tint) }
                }
                HStack(spacing: 4) {
                    Text(chat.updated, format: .dateTime.day().month().year().hour().minute())
                    Text(verbatim: "·")
                    Text("\(chat.turns) messages")
                }
                .font(.system(size: 11)).foregroundStyle(Dungeon.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !isCurrent {
                Button { open() } label: { Label("Continue", systemImage: "arrow.uturn.forward") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(!canContinue)
                    .help(canContinue ? "Make this the chat you're in and open it" : "Let \(name) out to continue this chat")
            }
            if chat.peer == nil {
                HoverIconButton(systemName: "square.and.arrow.up", help: "Save as a file", action: export)
            }
            HoverIconButton(systemName: "trash", help: "Delete this chat", tint: .red, action: delete)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hover ? 0.04 : 0)))
        .onHover { hover = $0 }
        .contextMenu {
            if !isCurrent { Button("Continue") { open() }.disabled(!canContinue) }
            if chat.peer == nil { Button("Save as File…") { export() } }
            Divider()
            Button("Delete…", role: .destructive) { delete() }
        }
    }
}

/// The chat in progress: its size, and Recap / New Chat.
private struct CurrentChat: View {
    let imp: ImpModel
    let profile: ImpProfile
    /// Recap and New Chat ask first: which one is asking.
    @State private var asking: String?

    var body: some View {
        let chat = imp.history.current
        let memory = chat.memory
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    (chat.title.isEmpty ? Text("New chat") : Text(verbatim: chat.title))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(details(memory)).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted).lineLimit(1)
                }
                InfoTip("\(profile.callName) sums up this chat and remembers only the recap and the last exchange. The whole chat stays to read. Use it when a chat grows too long; recap again as often as you like.")
                Spacer(minLength: 8)
                if imp.isRecapping {
                    ProgressView().controlSize(.small)
                }
                Button { confirm("recap") { imp.recapChat() } } label: {
                    Label(asking == "recap" ? "Recap now?" : "Recap", systemImage: "rectangle.compress.vertical")
                }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(!imp.canRecap)
                Button { confirm("new") { imp.newChat() } } label: {
                    Label(asking == "new" ? "Start new?" : "New Chat", systemImage: "plus.bubble")
                }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(imp.history.isEmpty)
                    .help("Start a fresh chat. This one stays in the list below.")
                Button { imp.openChat() } label: { Label("Open", systemImage: "bubble.left.and.bubble.right.fill") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Open the chat beside \(profile.callName)")
            }
            if let error = imp.recapError {
                StatusText(text: "Couldn't recap: \(error)", color: .red).help(error)
            }
        }
    }

    /// First click asks (for a few seconds), the second does it.
    private func confirm(_ what: String, _ action: () -> Void) {
        if asking == what { asking = nil; action(); return }
        asking = what
        Task { try? await Task.sleep(for: .seconds(3)); if asking == what { asking = nil } }
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
