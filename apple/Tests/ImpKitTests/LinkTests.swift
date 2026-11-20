import Testing
import Foundation
@testable import ImpKit

/// The adapters that turn screen geometry and sensor readings into what the core takes.
@Suite struct TossAdapterTests {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

    @Test func aFastFlingAtAnOuterEdgeIsAThrowAndACarryIsNot() throws {
        let out = try #require(Toss.desktopExit(cursor: CGPoint(x: 999, y: 200), velocity: CGVector(dx: 2000, dy: 0), screens: screens))
        #expect(out.side == .right && abs(out.height - 0.75) < 0.001)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 999, y: 200), velocity: CGVector(dx: 300, dy: 0), screens: screens) == nil)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 500, y: 200), velocity: CGVector(dx: 2000, dy: 0), screens: screens) == nil)
    }

    @Test func anImpTossedInLandsOnTheOutermostScreen() throws {
        let landing = try #require(Toss.desktopEntry(.after(exit: .right, height: 0.5, speed: 0), screens: screens))
        #expect(landing.point == CGPoint(x: 0, y: 400))
    }

    @Test func aFlickOnThePhoneIsAThrow() throws {
        let out = try #require(Toss.phoneExit(point: CGPoint(x: 3, y: 100), velocity: CGVector(dx: -1500, dy: 0), bounds: CGSize(width: 400, height: 800)))
        #expect(out.side == .left)
    }

    @Test func aSharpJoltIsAThrowAndBackAndForthIsAShake() {
        var detector = JoltDetector()
        var events: [JoltDetector.Event] = []
        for (i, x) in [3.0, 0, 0, 0, 0, 0, 0, 0, 0, 0].enumerated() { if let e = detector.feed(x: x, at: Double(i) * 0.1) { events.append(e) } }
        #expect(events == [.thrown(.right)])
        var shaker = JoltDetector()
        var shaken = false
        for (i, x) in [3.0, -3, 3, -3, 3].enumerated() { if shaker.feed(x: x, at: Double(i) * 0.05) == .shaken { shaken = true } }
        #expect(shaken && shaker.shakeStart == .right)
    }
}

@Suite struct LinkFilesTests {
    let base = URL(fileURLWithPath: "/Users/me/Library/Application Support/Imp/Workspace/abc")

    @Test func resolvesLikeTheBubble() {
        #expect(LinkFiles.resolve("voice.mp3", base: base)?.path == base.path + "/voice.mp3")
        #expect(LinkFiles.resolve("out/pic%20one.png", base: base)?.path == base.path + "/out/pic one.png")
        #expect(LinkFiles.resolve("/tmp/a.png", base: base)?.path == "/tmp/a.png")
        #expect(LinkFiles.resolve("file:///tmp/b.mov", base: base)?.path == "/tmp/b.mov")
        #expect(LinkFiles.resolve("voice.mp3#autoplay", base: base)?.path == base.path + "/voice.mp3")
        #expect(LinkFiles.resolve("../x.txt", base: base)?.path == base.deletingLastPathComponent().path + "/x.txt")
        #expect(LinkFiles.resolve("https://example.com/a.png", base: base) == nil)
        #expect(LinkFiles.resolve("  ", base: base) == nil)
        #expect(LinkFiles.isWeb("https://x.y/z.mp4") && !LinkFiles.isWeb("z.mp4"))
    }

    @Test func onlyWhatARepliesReferences() {
        let replies = ["Here you go: ![Pip says hi](pip%20hi.mp3#autoplay)", "Saved to [the report](/tmp/report.pdf \"Report\").",
                       "<img src=\"out/pic.png\"> and [site](https://example.com/a(1).png) and [x](<my file.txt>)"]
        #expect(LinkFiles.references(in: replies) == ["pip%20hi.mp3#autoplay", "/tmp/report.pdf", "https://example.com/a(1).png", "my file.txt", "out/pic.png"])
        #expect(LinkFiles.isMentioned("pip%20hi.mp3#autoplay", base: base, in: replies))
        #expect(LinkFiles.isMentioned("pip hi.mp3", base: base, in: replies))
        #expect(LinkFiles.isMentioned("/tmp/report.pdf", base: base, in: replies))
        #expect(LinkFiles.isMentioned("./out/../out/pic.png", base: base, in: replies))
        #expect(!LinkFiles.isMentioned("/etc/passwd", base: base, in: replies))
        // Prose that merely contains a path is not a reference, nor is a longer or shorter path.
        #expect(!LinkFiles.isMentioned("/etc/passwd", base: base, in: ["don't read /etc/passwd"]))
        #expect(!LinkFiles.isMentioned("/tmp/report", base: base, in: replies))
        #expect(!LinkFiles.isMentioned("/tmp/report.pdf.bak", base: base, in: replies))
        #expect(!LinkFiles.isMentioned("a", base: base, in: ["a"]))
    }

    @Test func anUntrustedHolderGetsOnlyFilesInTheImpsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linkfiles-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("imp"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: other)
        let replies = ["![a](pic.png) ![b](\(other.path)/secret.txt) ![c](out/secret.txt) ![d](../other/x.txt)"]
        #expect(LinkFiles.mayServe("pic.png", base: folder, in: replies, trusted: false))
        // Referenced, but outside the folder (directly, through a symlink, or by climbing out).
        for ref in ["\(other.path)/secret.txt", "out/secret.txt", "../other/x.txt"] {
            #expect(!LinkFiles.mayServe(ref, base: folder, in: replies, trusted: false))
            #expect(LinkFiles.mayServe(ref, base: folder, in: replies, trusted: true))
        }
        // Inside, but never referenced.
        #expect(!LinkFiles.mayServe("other.png", base: folder, in: replies, trusted: false))
        #expect(LinkFiles.mayServe("pic.png", base: folder, in: replies, trusted: true))
        #expect(!LinkFiles.isInside(folder.deletingLastPathComponent().appendingPathComponent("imp-evil/x"), folder: folder))
    }

    @Test func filePartsAndSpeechRoundTrip() throws {
        let part = LinkFilePart(name: "voice.mp3", size: 10, offset: 6, data: Data([1, 2, 3, 4]))
        #expect(part.isLast)
        let speech = LinkSpeech(id: UUID(), role: .reply, peer: "Pip", hue: 0.57, question: "Ready?", text: "Yes!")
        for m: LinkMessage in [.filePart(id: UUID(), part: part), .fileFailed(id: UUID(), reason: "gone"),
                               .speech(imp: UUID(), speech: speech), .speech(imp: UUID(), speech: nil),
                               .work(imp: UUID(), work: LinkWork(request: "Ready?", status: nil, partial: "", from: "Pip")),
                               .file(id: UUID(), imp: UUID(), ref: "voice.mp3")] {
            let body = try JSONEncoder.link.encode(m)
            #expect(try JSONDecoder.link.decode(LinkMessage.self, from: body) == m)
        }
    }
}

@Suite struct LinkChatWireTests {
    @Test func aTurnKeepsItsThoughtsAndAnswerOnTheWireAndOldOnesStillDecode() throws {
        let turn = LinkTurn(id: UUID(), date: Date(timeIntervalSince1970: 1_760_000_000), request: "It is done", from: "Bo",
                            reply: "Noted", failed: false, steps: ["Thought for 3s", "Read file"], thoughts: [0], answer: true)
        let message = LinkMessage.chat(imp: UUID(), turns: [turn])
        let back = try JSONDecoder().decode(LinkMessage.self, from: JSONEncoder().encode(message))
        #expect(back == message)
        let plain = LinkTurn(id: UUID(), date: Date(), request: "hi", reply: "yo", failed: false)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(json["thoughts"] == nil && json["answer"] == nil, "absent when there are none")
        let old = #"{"id":"00000000-0000-0000-0000-000000000021","date":1,"request":"a","reply":"b","failed":false,"steps":[]}"#
        let decoded = try JSONDecoder().decode(LinkTurn.self, from: Data(old.utf8))
        #expect(decoded.thoughts == nil && decoded.answer == nil)
    }

    @Test func aHomeListsOnlyChatsWithYouNewestFirstAndSendsShortTitles() {
        let talk = ChatSummary(id: UUID(), title: "talk", updated: Date(timeIntervalSince1970: 9), turns: 1, peer: UUID())
        let mine = ChatSummary(id: UUID(), title: String(repeating: "x", count: 500), updated: Date(timeIntervalSince1970: 3), turns: 1)
        let newer = ChatSummary(id: UUID(), title: "new", updated: Date(timeIntervalSince1970: 4), turns: 1)
        let list = LinkChats.list([talk, mine, newer])
        #expect(list.map(\.id) == [newer.id, mine.id])
        #expect(list[1].title.count == LinkChats.longestTitle)
    }
}
