import Foundation
import Testing
@testable import ImpKit

@Suite struct ConversationThreadingTests {
    let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.1)
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func asked(_ text: String, at seconds: Double) -> ChatTurn {
        ChatTurn(date: Date(timeIntervalSince1970: seconds), request: text, reply: "ok", via: .imp, sender: pip)
    }

    @Test func defaultsLiveInPreferences() {
        let p = ImpPreferences()
        #expect(p.talkThreading == .decides && p.talkWindowMinutes == 60)
        #expect(p.contextNoticeTokens == 250_000)
        #expect(ImpPreferences.contextNoticeChoices == [50_000, 100_000, 250_000, 500_000, 750_000, 1_000_000])
        var q = p
        q.talkWindowMinutes = 0
        #expect(q.talkWindowMinutes == 1)
        q.contextNoticeTokens = 1_000_000
        #expect(q.contextNoticeTokens == 1_000_000)
        q.contextNoticeTokens = 60_000                                    // not a choice: the default
        #expect(q.contextNoticeTokens == 250_000)
    }

    @Test func theRuleContinuesWhenRecentElseStartsNew() {
        let recent = now.addingTimeInterval(-10 * 60), old = now.addingTimeInterval(-3 * 3_600)
        #expect(TalkThreading.recent.continues(asked: nil, last: recent, windowMinutes: 60, now: now))
        #expect(!TalkThreading.recent.continues(asked: nil, last: old, windowMinutes: 60, now: now))
        #expect(!TalkThreading.recent.continues(asked: "continue", last: old, windowMinutes: 60, now: now))   // the sender isn't heard
        #expect(TalkThreading.always.continues(asked: "new", last: old, windowMinutes: 1, now: now))
        #expect(!TalkThreading.never.continues(asked: "continue", last: recent, windowMinutes: 60, now: now))
        #expect(!TalkThreading.always.continues(asked: nil, last: nil, windowMinutes: 60, now: now))       // nothing to continue
    }

    @Test func theSenderDecidesAndFallsBackToTheRule() {
        let recent = now.addingTimeInterval(-60), old = now.addingTimeInterval(-86_400)
        let d = TalkThreading.decides
        #expect(d.continues(asked: "continue", last: old, windowMinutes: 60, now: now))
        #expect(!d.continues(asked: "NEW", last: recent, windowMinutes: 60, now: now))
        #expect(d.continues(asked: nil, last: recent, windowMinutes: 60, now: now))
        #expect(!d.continues(asked: "maybe", last: old, windowMinutes: 60, now: now))
        #expect(!d.continues(asked: "continue", last: nil, windowMinutes: 60, now: now))
    }

    @Test func theToolOffersTheChoiceOnlyWhenTheSenderDecides() {
        func argument(_ on: Bool) -> JSONValue? {
            OwnTools.specs([.troupe], animations: [], imps: ["Pip"], browser: false, conversation: on).first?.inputSchema["properties"]?["conversation"]
        }
        #expect(argument(true) != nil && argument(false) == nil)
    }

    @Test func anotherConversationIsAnotherChatWithTheSameImp() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("talks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var h = ChatHistory(folder: folder)
        h.append(asked("one", at: 10), remembering: [.user("q"), .assistant("a")], withPeer: pip)
        h.append(asked("two", at: 20), remembering: [.user("q2"), .assistant("a2")], withPeer: pip)           // continues
        ChatHistory.flush()
        #expect(h.chats.count == 1 && h.memory(withPeer: pip.id).exchangeCount == 2)
        #expect(h.lastTalk(withPeer: pip.id) == Date(timeIntervalSince1970: 20))
        h.append(asked("three", at: 30), remembering: [.user("q3"), .assistant("a3")], withPeer: pip, continuing: false)
        ChatHistory.flush()
        #expect(h.chats.count == 2 && h.chats.allSatisfy { $0.peer == pip.id })
        #expect(h.memory(withPeer: pip.id).exchangeCount == 1)                                               // the newest is the new one
        h.append(asked("four", at: 40), remembering: [.user("q4"), .assistant("a4")], withPeer: pip)         // continues the new one
        #expect(h.chats.count == 2 && h.memory(withPeer: pip.id).exchangeCount == 2)
    }
}

@Suite struct LongChatNoticeTests {
    private func long(_ chars: Int) -> [ChatMessage] { [.user(String(repeating: "x", count: chars)), .assistant("ok")] }

    @Test func rememberingHasNoLimitByDefault() {
        #expect(ImpProfile.imp.memoryExchanges == ChatMemory.noLimit)
        var memory = ChatMemory()
        for i in 0..<60 { memory.remember([.user("q\(i)"), .assistant("a\(i)")]) }
        let sent = memory.context(system: "S", turn: .user("now"), exchanges: ImpProfile.imp.memoryExchanges)
        #expect(sent.count == 1 + 120 + 1)
        var limited = ImpProfile.imp
        limited.exchangesSent = 5
        #expect(limited.memoryExchanges == 5)
    }

    @Test func crossingTheThresholdRaisesTheNoticeOncePerChat() {
        var h = ChatHistory(folder: nil)
        h.append(ChatTurn(request: "a", reply: "b"), remembering: long(2_000))
        let fired810 = h.checkContext(threshold: 1_000, exchanges: .max, tools: true)          // about 500 tokens
        #expect(!fired810)
        #expect(!h.contextNoticeShown)
        h.append(ChatTurn(request: "c", reply: "d"), remembering: long(4_000))
        let fired5612 = h.checkContext(threshold: 1_000, exchanges: .max, tools: true)
        #expect(fired5612)
        #expect(h.contextNoticeShown)
        let fired6091 = h.checkContext(threshold: 1_000, exchanges: .max, tools: true)          // once
        #expect(!fired6091)
        h.startNew()
        #expect(!h.contextNoticeShown)
        h.append(ChatTurn(request: "e", reply: "f"), remembering: long(8_000))
        let fired7522 = h.checkContext(threshold: 1_000, exchanges: .max, tools: true)          // a new chat has its own
        #expect(fired7522)
    }

    @Test func dismissalIsRememberedAndNothingFiresWhenOff() {
        var h = ChatHistory(folder: nil)
        h.append(ChatTurn(request: "a", reply: "b"), remembering: long(8_000))
        let fired2389 = h.checkContext(threshold: 0, exchanges: .max, tools: true)
        #expect(!fired2389)
        let fired3519 = h.checkContext(threshold: 100, exchanges: .max, tools: true)
        #expect(fired3519)
        h.dismissContextNotice()
        #expect(!h.contextNoticeShown)
        let fired8504 = h.checkContext(threshold: 100, exchanges: .max, tools: true)
        #expect(!fired8504)
        #expect(!h.contextNoticeShown)
    }

    @Test func theNoticeSurvivesRelaunch() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        var h = ChatHistory(folder: folder)
        h.append(ChatTurn(request: "a", reply: "b"), remembering: long(8_000))
        h.checkContext(threshold: 100, exchanges: .max, tools: true)
        h.dismissContextNotice()
        ChatHistory.flush()
        var again = ChatHistory(folder: folder)
        #expect(again.current.contextDismissed == true && !again.contextNoticeShown)
        let fired4069 = again.checkContext(threshold: 100, exchanges: .max, tools: true)
        #expect(!fired4069)
    }
}

@Suite struct ConversationListTests {
    let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.1)
    let mo = ChatTurn.Sender(id: UUID(), name: "Mo", hue: 0.6)

    @Test func chatsWithYouLeaveOutTalksBetweenImps() {
        var h = ChatHistory(folder: nil)
        h.append(ChatTurn(request: "hi", reply: "hello"), remembering: [.user("hi"), .assistant("hello")])
        h.startNew()
        h.append(ChatTurn(request: "q", reply: "a", via: .imp, sender: pip), remembering: nil, withPeer: pip)
        #expect(h.chats.count == 2)
        #expect(h.chatsWithYou.count == 1 && h.chatsWithYou.allSatisfy { $0.peer == nil })
        let talkIDs = Set(h.chats.filter { $0.peer != nil }.map(\.id))
        #expect(talkIDs.isDisjoint(with: h.chatsWithYou.map(\.id)))
    }

    @Test func theJSONHoldsExactlyTheMessagesShown() {
        let turns = [ChatTurn(date: Date(timeIntervalSince1970: 100), request: "a", reply: "b"),
                     ChatTurn(date: Date(timeIntervalSince1970: 200), request: "c", reply: "oops", failed: true)]
        #expect(Transcript.turns(fromJSON: Transcript.json(turns)) == turns)
        let line = TalkLine(id: UUID(), date: Date(timeIntervalSince1970: 300), asker: pip, answerer: mo, question: "q", reply: "r", failed: false)
        let thread = TalkThread(peer: mo, lines: [line, line])
        #expect(Transcript.lines(fromJSON: Transcript.json(thread.lines)) == thread.lines)
        #expect(Transcript.turns(fromJSON: "[]") == [])
    }
}
