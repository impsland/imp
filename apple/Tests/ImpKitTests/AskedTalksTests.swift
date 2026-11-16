import Foundation
import Testing
@testable import ImpKit

/// What an Imp asked an Imp on another device shows in its Talks: the asker keeps a copy.
@MainActor @Suite("Asked talks")
struct AskedTalksTests {
    private let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.1)
    private let bo = ChatTurn.Sender(id: UUID(), name: "Bo", hue: 0.6)

    private func line(_ id: UUID = UUID(), question: String = "Hi?", reply: String = "Hello!", at date: Date = Date()) -> TalkLine {
        TalkLine(id: id, date: date, asker: pip, answerer: bo, question: question, reply: reply, failed: false)
    }

    @Test("A question the iPhone Imp asked a Mac Imp is in the iPhone Imp's Talks")
    func askerSeesItsOwnQuestion() {
        let asked = AskedTalks(file: nil)
        asked.record(line())
        let threads = TalkLog.threads(of: pip.id, from: asked.lines)
        #expect(threads.count == 1)
        #expect(threads.first?.peer.id == bo.id)
        #expect(threads.first?.lines.first?.reply == "Hello!")
    }

    @Test("The asker's copy and the answerer's turn, filed under the question's id, are one exchange")
    func bothCopiesCountOnce() {
        let question = UUID()
        let asked = AskedTalks(file: nil)
        asked.record(line(question))
        // The Mac files Bo's turn under the question's id (`ChatTurn(id:)`), and sends its lines.
        let filed = TalkLog.lines(answeredBy: bo, in: [Chat(turns: [ChatTurn(id: question, request: "Hi?", reply: "Hello!", via: .imp, sender: pip)])])
        let threads = TalkLog.threads(of: pip.id, from: asked.lines + filed)
        #expect(threads.first?.lines.count == 1)
    }

    @Test("Kept across launches, the newest only, and gone with the Imp that asked")
    func keptAndForgotten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("asked-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let asked = AskedTalks(file: file)
        for i in 0..<(AskedTalks.maxKept + 5) { asked.record(line(question: "Q\(i)", at: Date(timeIntervalSince1970: Double(i)))) }
        #expect(asked.lines.count == AskedTalks.maxKept)
        #expect(asked.lines.first?.question == "Q5")
        let again = AskedTalks(file: file)
        #expect(again.lines == asked.lines)
        again.forget(imp: pip.id)
        #expect(again.lines.isEmpty)
        #expect(AskedTalks(file: file).lines.isEmpty)
    }

    @Test("A line recorded again (same question) replaces the first")
    func sameQuestionReplaces() {
        let id = UUID()
        let asked = AskedTalks(file: nil)
        asked.record(line(id, reply: "…"))
        asked.record(line(id, reply: "Done"))
        #expect(asked.lines.map(\.reply) == ["Done"])
    }
}

/// The owner's words on the right, like any messenger, whoever asked.
@Suite("Talk sides")
struct TalkSideTests {
    @Test("The Imp whose talk it is speaks on the right, the other on the left")
    func ownerOnTheRight() {
        let pip = UUID(), bo = UUID()
        // Pip asked Bo: in Pip's Talks the question is Pip's (right) and the answer Bo's (left).
        #expect(TalkSide(speaker: pip, owner: pip) == .mine)
        #expect(TalkSide(speaker: bo, owner: pip) == .theirs)
        // The same exchange in Bo's Talks is the other way round.
        #expect(TalkSide(speaker: bo, owner: bo) == .mine)
        #expect(TalkSide(speaker: pip, owner: bo) == .theirs)
    }
}
