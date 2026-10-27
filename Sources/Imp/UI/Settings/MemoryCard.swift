import ImpKit
import SwiftUI

/// What the Imp is sent of the chat you're in, and the chat itself: recap it when it's grown
/// long, or start a new one (saved chats stay in the chat's list).
struct MemoryCard: View {
    let model: AppModel
    @Binding var imp: ImpProfile

    private var name: String { imp.name.isEmpty ? "this Imp" : imp.name }
    private static let lengths = [5, 10, 20, 50, 100, 200]

    var body: some View {
        Card("Memory", icon: "brain",
             info: "With every message, \(name) is sent the chat you're in: its recent exchanges (each of your messages with everything it led to). Chats are saved: switch between them at the top of the chat.") {
            Row("Include tool calls",
                info: "Send the tools \(name) used, and what they returned, with the rest of the chat. It can then reuse a file or link a tool made instead of making it again. Off: only what you and \(name) said (smaller, cheaper).") {
                Toggle("", isOn: Binding(get: { imp.remembersToolCalls }, set: { imp.sendsToolCalls = $0 ? nil : false }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            CardDivider()
            Row("Exchanges sent",
                info: "How far back \(name) remembers: the last exchanges of the chat sent with each message. Fewer is faster and cheaper; anything older is still in the chat to read.") {
                Picker("", selection: Binding(get: { imp.memoryExchanges },
                                              set: { imp.exchangesSent = $0 == ChatMemory.defaultExchanges ? nil : $0 })) {
                    ForEach(Self.lengths, id: \.self) { Text("Last \($0)").tag($0) }
                    if !Self.lengths.contains(imp.memoryExchanges) { Text("Last \(imp.memoryExchanges)").tag(imp.memoryExchanges) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            CardDivider()
            if let live = model.imp(imp.id) {
                CurrentChat(imp: live, profile: imp)
            } else {
                Row("Current chat", info: "Let \(name) out to chat with it, recap a chat or start a new one.") {
                    StatusText(text: "At home")
                }
            }
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
                    Text(chat.title.isEmpty ? "New chat" : chat.title)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(details(memory)).font(.system(size: 11.5)).foregroundStyle(Dungeon.muted).lineLimit(1)
                }
                InfoTip("Recap: \(profile.name) sums up this chat, then remembers only the recap and the last exchange (the whole chat stays there to read). Use it when a long chat no longer fits the model, or to send less.")
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
                Button { imp.openChat() } label: { Label("Open", systemImage: "bubble.left.and.bubble.right.fill") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Open the chat beside \(profile.name)")
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
        guard !memory.isEmpty else { return "Nothing said yet" }
        let n = memory.exchangeCount
        let tokens = memory.estimatedTokens(exchanges: profile.memoryExchanges, tools: profile.remembersToolCalls)
        let size = tokens >= 1000 ? String(format: "%.1fk", Double(tokens) / 1000) : "\(tokens)"
        return "\(n) exchange\(n == 1 ? "" : "s")\(memory.recap == nil ? "" : " + recap") · about \(size) tokens sent"
    }
}
