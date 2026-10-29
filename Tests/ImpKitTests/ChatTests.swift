import Foundation
import Testing
@testable import ImpKit

/// The exchange from the bug report: a tool call and its result between the question and the answer.
private func toolExchange(_ ask: String = "Make it sound nicer", file: String = "affirmation.mp3") -> [ChatMessage] {
    let call = ToolCall(id: "call_1", name: "Speech__generate_speech", arguments: #"{"output":"\#(file)"}"#)
    return [.user(ask), .assistant(nil, toolCalls: [call]), .tool(id: "call_1", content: "Saved speech: /tmp/\(file)"),
            .assistant("Done: ![voice](\(file))")]
}

@Suite struct ChatMemoryTests {
    @Test func remembersToolCallsAndTheirResultsWithoutPictureBytes() {
        var m = ChatMemory()
        let pixel = EncodedImage(data: Data([1, 2, 3]), mimeType: "image/png")
        m.remember([Briefing.message("Look", image: pixel, imagePath: "/tmp/p.png"), .assistant("Nice")])
        m.remember(toolExchange())
        #expect(m.messages.allSatisfy { $0.images == nil })
        let context = m.context(system: "You are Imp.", turn: .user("Play it again"))
        #expect(context.map(\.role) == ["system", "user", "assistant", "user", "assistant", "tool", "assistant", "user"])
        #expect(context[4].toolCalls?.first?.name == "Speech__generate_speech" && context[5].toolCallID == "call_1")
    }

    @Test func toolCallsCanBeLeftOut() {
        var m = ChatMemory()
        m.remember(toolExchange())
        let context = m.context(system: "S", turn: .user("Again"), tools: false)
        #expect(context.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(context[2].content == "Done: ![voice](affirmation.mp3)")
    }

    @Test func sendsWholeExchangesSoToolCallsKeepTheirResults() {
        var m = ChatMemory()
        for i in 0..<5 { m.remember(toolExchange("q\(i)")) }
        #expect(m.exchangeCount == 5)
        let context = m.context(system: "S", turn: .user("next"), exchanges: 2)
        #expect(context.count == 1 + 2 * 4 + 1)
        #expect(context[1].content == "q3" && context[2].toolCalls != nil)
    }

    @Test func clipsLongToolResultsAndKeepsAtMostTheStoredExchanges() {
        var m = ChatMemory()
        let long = String(repeating: "x", count: ChatMemory.toolResultLimit + 500)
        m.remember([.user("read"), .assistant(nil, toolCalls: [ToolCall(id: "c", name: "shell", arguments: "{}")]),
                    .tool(id: "c", content: long), .assistant("ok")])
        #expect(m.messages[2].content!.count < long.count && m.messages[2].content!.hasSuffix("(clipped: 500 more characters)"))
        for i in 0..<(ChatMemory.storedExchanges + 3) { m.remember([.user("q\(i)"), .assistant("a\(i)")]) }
        #expect(m.exchangeCount == ChatMemory.storedExchanges && m.messages.first?.content == "q3")
    }

    @Test func aRecapStandsForAllButTheLastExchange() {
        var m = ChatMemory()
        m.remember([.user("My name is Ann"), .assistant("Hi Ann")])
        m.remember(toolExchange())
        m.recapped("  - The user is Ann.\n- Made affirmation.mp3  ")
        #expect(m.recap == "- The user is Ann.\n- Made affirmation.mp3" && m.exchangeCount == 1)
        #expect(m.messages.first?.content == "Make it sound nicer")
        let context = m.context(system: "You are Imp.", turn: .user("Play it"))
        #expect(context[0].content == "You are Imp.\n\n" + Recap.preface + "- The user is Ann.\n- Made affirmation.mp3")
        #expect(m.estimatedTokens() > 0)
    }

    @Test func theRecapRequestCarriesTheWholeChat() {
        var m = ChatMemory(recap: "- Earlier: picked a voice")
        m.remember(toolExchange())
        let request = Recap.request(m, name: "Fizz")
        #expect(request.map(\.role) == ["system", "user"] && request[0].content!.contains("Fizz"))
        let text = request[1].content!
        #expect(text.contains("[Earlier recap]\n- Earlier: picked a voice"))
        #expect(text.contains("User: Make it sound nicer"))
        #expect(text.contains("Assistant called Speech__generate_speech({\"output\":\"affirmation.mp3\"})"))
        #expect(text.contains("Tool result: Saved speech: /tmp/affirmation.mp3"))
        #expect(text.contains("Assistant: Done: ![voice](affirmation.mp3)"))
    }
}

@Suite struct ToolLabelTests {
    @Test func toolCallsReadLikeWhatTheImpIsDoing() {
        #expect(ToolLabel(tool: ShellTool.name, arguments: #"{"command":"pmset -g batt"}"#).title == "pmset -g batt")
        #expect(ToolLabel(tool: ShellTool.name, arguments: "{}").title == "Running a command")
        #expect(ToolLabel.commandLine(String(repeating: "x", count: 100), limit: 10) == "xxxxxxxxxx…")
        let mcp = ToolLabel(tool: "files__read_file", arguments: "{}")
        #expect(mcp.title == "Files › read file" && mcp.icon == "hammer")
        // The whole request, readable: the full command, or indented arguments.
        #expect(ToolLabel(tool: ShellTool.name, arguments: #"{"command":"ls\npwd"}"#).request == "ls\npwd")
        #expect(ToolLabel(tool: "files__read_file", arguments: #"{"path":"/tmp/a"}"#).request == "{\n  \"path\" : \"/tmp/a\"\n}")
        #expect(ToolLabel(tool: "files__read_file", arguments: "not json").request == "not json")
    }
}

@Suite struct ChatHistoryTests {
    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imp-chats-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func keepsChatsAndTheirMemoryAcrossLaunches() {
        let folder = tempFolder()
        var h = ChatHistory(folder: folder)
        #expect(h.isEmpty && h.chats.isEmpty)
        let step = ChatTurn.Step(icon: "terminal", title: "ls", request: "ls", response: "a.txt", failed: false)
        h.append(ChatTurn(request: "What's here?\nIn my folder", reply: "One file.", steps: [step]),
                 remembering: [.user("What's here?"), .assistant("One file.")])
        h.append(ChatTurn(request: "Fail", reply: "Out of credits", failed: true))
        ChatHistory.flush()
        let reopened = ChatHistory(folder: folder)
        #expect(reopened.turns.map(\.request) == ["What's here?\nIn my folder", "Fail"])
        #expect(reopened.turns[0].steps == [step] && reopened.turns[1].failed)
        #expect(reopened.current.title == "What's here?" && reopened.chats.map(\.id) == [h.current.id])
        // A failure isn't remembered: the model never answered it.
        #expect(reopened.current.memory.exchangeCount == 1)
    }

    @Test func newChatsAndSwitchingBack() {
        let folder = tempFolder()
        var h = ChatHistory(folder: folder)
        h.startNew()                                              // nothing to leave behind yet
        #expect(h.chats.isEmpty)
        h.append(ChatTurn(request: "First", reply: "1"), remembering: [.user("First"), .assistant("1")])
        let first = h.current.id
        h.startNew()
        #expect(h.isEmpty && h.chats.map(\.id) == [first])
        h.append(ChatTurn(request: "Second", reply: "2"), remembering: [.user("Second"), .assistant("2")])
        let second = h.current.id
        #expect(h.chats.map(\.id) == [second, first])
        h.open(first)
        #expect(h.current.id == first && h.current.memory.messages.map(\.content) == ["First", "1"])
        h.rename(second, to: "  Renamed ")
        #expect(h.chats.map(\.title) == ["Renamed", "First"])          // renaming doesn't reorder
        ChatHistory.flush()
        let reopened = ChatHistory(folder: folder)
        #expect(reopened.current.id == first && reopened.chats.map(\.title) == ["Renamed", "First"])
        var back = reopened
        back.open(second)
        #expect(back.current.title == "Renamed" && back.turns.map(\.request) == ["Second"])
    }

    @Test func recapShowsInTheChatAndReplacesTheMemory() {
        var h = ChatHistory(folder: nil)
        h.append(ChatTurn(request: "a", reply: "1"), remembering: [.user("a"), .assistant("1")])
        h.append(ChatTurn(request: "b", reply: "2"), remembering: toolExchange("b"))
        h.recap("- a, then b")
        #expect(h.turns.map(\.via) == [nil, nil, .recap] && h.turns.last?.reply == "- a, then b")
        #expect(h.current.memory.recap == "- a, then b" && h.current.memory.messages.first?.content == "b")
        #expect(h.current.title == "a")
    }

    @Test func deletingAChat() {
        let folder = tempFolder()
        var h = ChatHistory(folder: folder)
        h.append(ChatTurn(request: "keep", reply: "1"))
        let kept = h.current.id
        h.startNew()
        h.append(ChatTurn(request: "drop", reply: "2"))
        let dropped = h.current.id
        h.delete(dropped)
        #expect(h.isEmpty && h.chats.map(\.id) == [kept])
        ChatHistory.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(dropped.uuidString).json").path))
        let reopened = ChatHistory(folder: folder)
        #expect(reopened.isEmpty && reopened.chats.map(\.id) == [kept])
        var all = reopened
        all.deleteAll()
        ChatHistory.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.path) && ChatHistory(folder: folder).chats.isEmpty)
    }

    @Test func pagesFromTheNewestAndKeepsOnlyTheLimit() {
        var h = ChatHistory(folder: nil)
        for i in 0..<(ChatHistory.limit + 5) { h.append(ChatTurn(request: "q\(i)", reply: "a\(i)")) }
        #expect(h.turns.count == ChatHistory.limit && h.turns.first?.request == "q5")
        #expect(h.latest(2).map(\.request) == ["q\(ChatHistory.limit + 3)", "q\(ChatHistory.limit + 4)"])
        #expect(h.latest(1000).count == ChatHistory.limit)
    }
}

@Suite struct ImpTalkTests {
    private let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.58)
    private let mo = ChatTurn.Sender(id: UUID(), name: "Mo", hue: 0.33)

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imp-talk-\(UUID().uuidString)", isDirectory: true)
    }

    private func asked(_ text: String, by sender: ChatTurn.Sender) -> ChatTurn {
        ChatTurn(request: text, reply: "ok", via: .imp, sender: sender)
    }

    @Test func eachPeerGetsAChatOfItsOwnAndYourChatIsLeftAlone() {
        let folder = tempFolder()
        var h = ChatHistory(folder: folder)
        h.append(ChatTurn(request: "Hello", reply: "Hi"), remembering: [.user("Hello"), .assistant("Hi")])
        let yours = h.current.id
        h.append(asked("Lunch?", by: pip), remembering: [.user("Pip asks: lunch?"), .assistant("Sure")], withPeer: pip)
        h.append(asked("Dinner?", by: mo), remembering: [.user("Mo asks: dinner?"), .assistant("No")], withPeer: mo)
        h.append(asked("And tea?", by: pip), remembering: [.user("Pip asks: tea?"), .assistant("Yes")], withPeer: pip)
        // The chat you're in is untouched, and so is its memory.
        #expect(h.current.id == yours && h.turns.map(\.request) == ["Hello"] && h.current.memory.exchangeCount == 1)
        #expect(h.chats.count == 3)
        let pips = h.chat(with: pip.id)
        #expect(pips?.title == "With Pip" && pips?.turns == 2 && h.chat(with: mo.id)?.turns == 1)
        #expect(h.memory(withPeer: pip.id).messages.map(\.content) == ["Pip asks: lunch?", "Sure", "Pip asks: tea?", "Yes"])
        #expect(h.memory(withPeer: UUID()).isEmpty)
        // Found by the Imp's id, not the title, so renaming it changes nothing.
        h.rename(pips!.id, to: "Gossip")
        h.append(asked("More?", by: pip), withPeer: pip)
        #expect(h.chats.filter { $0.peer == pip.id }.map(\.turns) == [3] && h.chats.first { $0.peer == pip.id }?.title == "Gossip")
        // Kept across launches, with who said what.
        ChatHistory.flush()
        var reopened = ChatHistory(folder: folder)
        #expect(reopened.current.id == yours && reopened.chats.count == 3)
        #expect(reopened.memory(withPeer: mo.id).messages.count == 2)
        reopened.open(pips!.id)
        #expect(reopened.turns.first?.sender == pip && reopened.turns.first?.via == .imp && reopened.current.peer == pip.id)
    }

    @Test func talkingInTheChatYoureInAddsToIt() {
        var h = ChatHistory(folder: nil)
        h.append(asked("Hi", by: pip), remembering: [.user("a"), .assistant("b")])
        #expect(h.current.title == "Pip: Hi" && h.current.peer == nil && h.chats.count == 1)
    }

    @Test func aPeerChatIsTheCurrentOneWhenYouOpenedIt() {
        let folder = tempFolder()
        var h = ChatHistory(folder: folder)
        h.append(asked("Lunch?", by: pip), remembering: [.user("q"), .assistant("a")], withPeer: pip)
        ChatHistory.flush()
        h.open(h.chat(with: pip.id)!.id)
        h.append(asked("Dinner?", by: pip), remembering: [.user("q2"), .assistant("a2")], withPeer: pip)
        #expect(h.chats.count == 1 && h.turns.count == 2 && h.memory(withPeer: pip.id).exchangeCount == 2)
    }

    @Test func theModelPicksTheChatOnlyWhenItDecides() {
        #expect(ImpTalk.own.place(asked: "shared") == .own && ImpTalk.shared.place(asked: "own") == .shared)
        #expect(ImpTalk.decides.place(asked: "shared") == .shared && ImpTalk.decides.place(asked: nil) == .own)
        #expect(ImpPreferences().impTalk == .own)
        func chatArgument(_ talk: ImpTalk) -> Bool {
            let spec = OwnTools.specs([.troupe], animations: [], imps: ["Pip"], browser: false, talk: talk).first
            return spec?.inputSchema["properties"]?["chat"] != nil
        }
        #expect(chatArgument(.decides) && !chatArgument(.own) && !chatArgument(.shared))
    }
}
