import Foundation
import Testing
@testable import ImpKit

@Suite struct ChatFileTests {
    private func sample() -> Chat {
        var memory = ChatMemory(recap: "- The user is Ann")
        memory.remember([.user("Play it"), .assistant(nil, toolCalls: [ToolCall(id: "c", name: "play", arguments: "{}")]),
                         .tool(id: "c", content: "ok"), .assistant("Playing")])
        return Chat(title: "Music: night/day", turns: [ChatTurn(request: "Play it", reply: "Playing", via: .typed)], memory: memory)
    }

    @Test func aChatGoesOutAndComesBackAsANewOne() throws {
        let chat = sample()
        let text = ChatFile.text(chat, imp: "Pip", app: "1.11.0")
        #expect(text.contains("\"impChat\"") && text.contains("Pip") && text.contains("1.11.0"))
        let back = try ChatFile.read(text)
        #expect(back.id != chat.id && back.title == chat.title && back.peer == nil)
        #expect(back.turns.map(\.request) == ["Play it"] && back.turns[0].reply == "Playing")
        #expect(back.memory.recap == "- The user is Ann" && back.memory.messages.count == 4)
        // The model is sent it just as before.
        #expect(back.memory.context(system: "S", turn: .user("x")).map(\.role) == chat.memory.context(system: "S", turn: .user("x")).map(\.role))
    }

    @Test func readsABareChatAndRefusesWhatIsntOne() throws {
        let bare = try ChatFile.read(#"{"title": "T", "turns": [{"request": "Hi", "reply": "Hello"}]}"#)
        #expect(bare.title == "T" && bare.turns.count == 1)
        #expect(throws: ChatFile.Failure.notAChat) { try ChatFile.read("not json") }
        #expect(throws: ChatFile.Failure.notAChat) { try ChatFile.read(#"{"imp": 3, "triggers": []}"#) }
        #expect(throws: ChatFile.Failure.empty) { try ChatFile.read(#"{"impChat": 1, "chat": {"turns": []}}"#) }
    }

    @Test func onlyChatsWithYouAreExported() {
        var chat = sample()
        #expect(ChatFile.canExport(chat))
        chat.peer = UUID()
        #expect(!ChatFile.canExport(chat) && !ChatFile.canExport(Chat()))
    }

    @Test func fileNamesAreSafe() {
        #expect(ChatFile.fileName(sample()) == "Music  night day.json")
        #expect(ChatFile.fileName(Chat()) == "Chat.json")
    }

    @Test func anImportedChatIsListedFirstWithoutChangingTheCurrentOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("imp-chatfile-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var h = ChatHistory(folder: folder)
        h.append(ChatTurn(request: "Mine", reply: "ok"))
        let current = h.current.id
        h.adopt(try ChatFile.read(ChatFile.text(sample())))
        #expect(h.current.id == current && h.chats.count == 2 && h.chats.first?.title == "Music: night/day")
        #expect(h.chat(h.chats[0].id)?.memory.recap == "- The user is Ann")
    }
}
