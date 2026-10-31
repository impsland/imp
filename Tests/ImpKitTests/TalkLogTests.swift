import Foundation
import Testing
@testable import ImpKit

@Suite struct TalkLogTests {
    let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.1)
    let mo = ChatTurn.Sender(id: UUID(), name: "Mo", hue: 0.6)
    let zed = ChatTurn.Sender(id: UUID(), name: "Zed", hue: 0.3)

    private func asked(_ text: String, by sender: ChatTurn.Sender, at seconds: Double, reply: String = "ok") -> ChatTurn {
        ChatTurn(date: Date(timeIntervalSince1970: seconds), request: text, reply: reply, via: .imp, sender: sender)
    }

    @Test func bothHalvesOfATalkComeTogetherInOrder() {
        // Pip asked Mo twice (in Mo's chats), Mo asked Pip once (in Pip's chat with you, a shared talk).
        var moWithPip = Chat(peer: pip.id)
        moWithPip.turns = [asked("sonnet?", by: pip, at: 10), asked("shorter?", by: pip, at: 30)]
        var pipWithYou = Chat()
        pipWithYou.turns = [ChatTurn(request: "hi", reply: "hello"), asked("rhyme for moon?", by: mo, at: 20, reply: "spoon")]
        let lines = TalkLog.lines(answeredBy: mo, in: [moWithPip]) + TalkLog.lines(answeredBy: pip, in: [pipWithYou])
        let threads = TalkLog.threads(of: pip.id, from: lines + lines)          // overlap counts once
        #expect(threads.count == 1)
        #expect(threads[0].peer == mo)
        #expect(threads[0].lines.map(\.question) == ["sonnet?", "rhyme for moon?", "shorter?"])
        #expect(threads[0].lines.map(\.asker.name) == ["Pip", "Mo", "Pip"])
        #expect(TalkLog.threads(of: mo.id, from: lines).first?.lines.count == 3)
    }

    @Test func onlyTalksTheImpTookPartInNewestFirst() {
        var mo = Chat(peer: pip.id)
        mo.turns = [asked("a", by: pip, at: 1)]
        var zedChat = Chat(peer: pip.id)
        zedChat.turns = [asked("b", by: pip, at: 5)]
        var other = Chat(peer: zed.id)
        other.turns = [asked("not pip's", by: zed, at: 9)]
        let lines = TalkLog.lines(answeredBy: self.mo, in: [mo, other]) + TalkLog.lines(answeredBy: zed, in: [zedChat])
        let threads = TalkLog.threads(of: pip.id, from: lines)
        #expect(threads.map(\.peer.name) == ["Zed", "Mo"])
        #expect(threads.allSatisfy { $0.lines.allSatisfy { $0.asker.id == pip.id || $0.answerer.id == pip.id } })
    }

    @Test func aPeerIsNamedAsItWasLastSeen() {
        let renamed = ChatTurn.Sender(id: mo.id, name: "Moxie", hue: 0.9)
        var chat = Chat(peer: mo.id)
        chat.turns = [asked("old", by: mo, at: 1), asked("new", by: renamed, at: 2)]
        let thread = TalkLog.threads(of: pip.id, from: TalkLog.lines(answeredBy: pip, in: [chat]))[0]
        #expect(thread.peer == renamed)
    }

    @Test func linkLinesStayLightAndRoundTrip() throws {
        let line = TalkLine(id: UUID(), date: Date(timeIntervalSince1970: 3), asker: pip, answerer: mo,
                            question: String(repeating: "q", count: 9_000), reply: "r", failed: false)
        let sent = TalkLog.forLink(Array(repeating: line, count: 1) + (0..<400).map { i in
            TalkLine(id: UUID(), date: Date(timeIntervalSince1970: Double(10 + i)), asker: mo, answerer: pip, question: "\(i)", reply: "", failed: true)
        })
        #expect(sent.count == 300 && sent.last?.question == "399")
        #expect(TalkLog.forLink([line])[0].question.count == 1_500)
        let update = LinkUpdate.talks(imp: pip.id, lines: sent)
        let data = try LinkFrame.encode(update)
        var frames = LinkFrame()
        let body = try #require(try frames.feed(data).first)
        #expect(LinkFrame.decode(LinkUpdate.self, body) == update)
        #expect(LinkFrame.decode(LinkRequest.self, try JSONEncoder.link.encode(LinkRequest.talks(imp: pip.id))) == .talks(imp: pip.id))
    }
}
