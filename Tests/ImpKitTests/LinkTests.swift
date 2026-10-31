import Testing
import Foundation
import Network
@testable import ImpKit

@Suite struct LinkFrameTests {
    @Test func roundTripsMessagesAcrossSplitReads() throws {
        let a = LinkMessage.ask(imp: UUID(), text: "Rename the screenshots 🗂️")
        let b = LinkMessage.pass(transfer: UUID(), imp: LinkImp(ImpProfile.imp), entry: LinkEntry(side: .left, height: 0.25, speed: 2100), home: nil, ticket: nil)
        let bytes = try LinkFrame.encode(a) + LinkFrame.encode(b)
        var framer = LinkFrame()
        var bodies: [Data] = []
        // A byte at a time: frames only come out whole.
        for byte in bytes { bodies += try framer.feed(Data([byte])) }
        #expect(bodies.count == 2)
        #expect(LinkFrame.decode(LinkMessage.self, bodies[0]) == a)
        #expect(LinkFrame.decode(LinkMessage.self, bodies[1]) == b)
    }

    @Test func refusesHugeFrames() throws {
        var framer = LinkFrame()
        let huge = UInt32(LinkProtocol.maxFrame + 1).bigEndian
        #expect(throws: LinkFrame.Failure.self) { try framer.feed(withUnsafeBytes(of: huge) { Data($0) }) }
        // Just at the limit is fine: it only waits for the rest.
        var edge = LinkFrame()
        #expect(try edge.feed(withUnsafeBytes(of: UInt32(LinkProtocol.maxFrame).bigEndian) { Data($0) }).isEmpty)
    }

    @Test func unknownMessagesAreIgnored() {
        #expect(LinkFrame.decode(LinkMessage.self, Data(#"{"teleport":{"imp":"x"}}"#.utf8)) == nil)
        #expect(LinkFrame.decode(LinkMessage.self, Data("garbage".utf8)) == nil)
    }

    @Test func messagesRoundTrip() throws {
        let imp = LinkImp(ImpProfile.imp)
        let turn = LinkTurn(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), request: "hi", from: "Pip",
                            reply: "hello", failed: false, steps: ["Ran a command"])
        let beats = [AnimationBeat(duration: 0.4, mood: "happy")]
        let card = LinkCard(device: LinkIdentity(name: "Mac", kind: .mac).device, door: LinkCrypto.randomKey(), routes: LinkRoutes(hosts: ["a.local"]))
        for m: LinkMessage in [.pass(transfer: UUID(), imp: imp, entry: LinkEntry(side: .right, height: 0.3, speed: 1800), home: card, ticket: LinkCrypto.mintTicket()),
                               .took(transfer: UUID()), .declined(transfer: UUID(), reason: .full),
                               .claim(imp: imp.id, ticket: LinkCrypto.mintTicket()), .gone(imp: imp.id),
                               .stage(imps: [LinkStaged(imp: imp, home: UUID())]),
                               .chat(imp: imp.id, turns: [turn]),
                               .work(imp: imp.id, work: LinkWork(request: "hi", status: "Thinking", partial: "Hel")),
                               .work(imp: imp.id, work: nil),
                               .animate(imp: imp.id, beats: beats),
                               .message(id: UUID(), from: imp, to: UUID(), toHome: UUID(), text: "hi", forwarded: false),
                               .answer(id: UUID(), text: "yes", failed: false)] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(m)).first)
            #expect(LinkFrame.decode(LinkMessage.self, body) == m)
            #expect(m.isSound)
        }
    }

    @Test func soundnessChecksSizesAndKeys() {
        let imp = LinkImp(ImpProfile.imp)
        let long = String(repeating: "a", count: LinkProtocol.maxText + 1)
        #expect(LinkMessage.ask(imp: imp.id, text: String(repeating: "a", count: LinkProtocol.maxText)).isSound)
        #expect(!LinkMessage.ask(imp: imp.id, text: long).isSound)
        #expect(!LinkMessage.answer(id: UUID(), text: long, failed: false).isSound)
        #expect(!LinkMessage.message(id: UUID(), from: imp, to: UUID(), toHome: UUID(), text: long, forwarded: false).isSound)
        #expect(!LinkMessage.claim(imp: imp.id, ticket: Data(repeating: 1, count: 31)).isSound)
        #expect(!LinkMessage.routes(door: Data(), routes: .none).isSound)
        // A card and a ticket come together.
        #expect(!LinkMessage.pass(transfer: UUID(), imp: imp, entry: LinkEntry(side: .left, height: 0, speed: 0), home: nil, ticket: LinkCrypto.mintTicket()).isSound)
        #expect(!LinkMessage.stage(imps: Array(repeating: LinkStaged(imp: imp, home: UUID()), count: 65)).isSound)
    }

    @Test func routesAndDevicesAreCheckedWhereverTheyComeFrom() {
        let bad = Data(#"{"hosts":["a b"],"port":47824}"#.utf8)
        #expect(LinkFrame.decode(LinkRoutes.self, bad) == nil)
        #expect(LinkFrame.decode(LinkRoutes.self, Data(#"{"hosts":["a.local"],"port":0}"#.utf8)) == nil)
        let device = Data(#"{"id":"\#(UUID().uuidString)","name":"x","kind":"mac","key":"AAAA"}"#.utf8)
        #expect(LinkFrame.decode(LinkDevice.self, device) == nil)
    }

    @Test func entryCarriesOnTheWayItWent() {
        let e = LinkEntry.after(exit: .left, height: 0.4, speed: 1500)
        #expect(e.side == .right && e.height == 0.4)
        #expect(LinkEntry(side: .left, height: 7, speed: -3) == LinkEntry(side: .left, height: 1, speed: 0))
    }
}

@Suite struct TossTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// A second display to the right of the laptop, taller and offset.
    let display = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    @Test func flingOffTheEdgeIsAThrow() throws {
        let exit = try #require(Toss.desktopExit(cursor: CGPoint(x: 3, y: 736), velocity: CGVector(dx: -2200, dy: 150), screens: [laptop]))
        #expect(exit.side == .left)
        #expect(abs(exit.height - 0.25) < 0.01)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 1511, y: 491), velocity: CGVector(dx: 1800, dy: 0), screens: [laptop])?.side == .right)
    }

    @Test func approachingAnOuterSideNamesItAndTheSameHeightAsAThrow() throws {
        let near = try #require(Toss.desktopApproach(cursor: CGPoint(x: 150, y: 736), within: 200, screens: [laptop]))
        #expect(near.side == .left && near.screen == laptop)
        #expect(abs(near.height - 0.25) < 0.01)
        let exit = try #require(Toss.desktopExit(cursor: CGPoint(x: 3, y: 736), velocity: CGVector(dx: -2200, dy: 0), screens: [laptop]))
        #expect(exit.height == near.height)
        #expect(Toss.desktopApproach(cursor: CGPoint(x: 700, y: 500), within: 200, screens: [laptop]) == nil)
    }

    @Test func theSeamBetweenDisplaysHasNoDoors() throws {
        let screens = [laptop, display]
        // Beside the seam, where the displays meet: carrying across, not a way out.
        #expect(Toss.desktopApproach(cursor: CGPoint(x: 1450, y: 500), within: 200, screens: screens) == nil)
        // Where the taller display reaches past the laptop's height, its left side is outer again.
        #expect(Toss.desktopApproach(cursor: CGPoint(x: 1600, y: 1200), within: 200, screens: screens)?.side == .left)
        // The far side of the right-hand display.
        #expect(try #require(Toss.desktopApproach(cursor: CGPoint(x: 4000, y: 500), within: 200, screens: screens)).side == .right)
    }

    @Test func carriesAreNotThrows() {
        // Too slow, too vertical, or still far from the edge.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 3, y: 500), velocity: CGVector(dx: -600, dy: 0), screens: [laptop]) == nil)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 3, y: 500), velocity: CGVector(dx: -1500, dy: 2500), screens: [laptop]) == nil)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 400, y: 500), velocity: CGVector(dx: -3000, dy: 0), screens: [laptop]) == nil)
        // Moving away from the edge it's next to.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 3, y: 500), velocity: CGVector(dx: 3000, dy: 0), screens: [laptop]) == nil)
    }

    @Test func edgesBetweenDisplaysAreCrossedNotThrownOff() {
        let screens = [laptop, display]
        // Laptop's right edge has the display beyond it: a carry across.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 1510, y: 500), velocity: CGVector(dx: 2500, dy: 0), screens: screens) == nil)
        // The display's left edge, likewise.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 1514, y: 500), velocity: CGVector(dx: -2500, dy: 0), screens: screens) == nil)
        // The outer edges throw.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 2, y: 500), velocity: CGVector(dx: -2500, dy: 0), screens: screens)?.side == .left)
        #expect(Toss.desktopExit(cursor: CGPoint(x: 4071, y: 900), velocity: CGVector(dx: 2500, dy: 0), screens: screens)?.side == .right)
        // Above the laptop's top, the display's left edge has nothing beyond it: that part is outer.
        #expect(Toss.desktopExit(cursor: CGPoint(x: 1513, y: 1100), velocity: CGVector(dx: -2500, dy: 0), screens: screens)?.side == .left)
    }

    @Test func arrivalsComeInOnTheOutermostScreen() throws {
        let screens = [laptop, display]
        let left = try #require(Toss.desktopEntry(LinkEntry(side: .left, height: 0.5, speed: 0), screens: screens))
        #expect(left.screen == laptop && left.point == CGPoint(x: 0, y: 491))
        let right = try #require(Toss.desktopEntry(LinkEntry(side: .right, height: 0, speed: 0), screens: screens))
        #expect(right.screen == display && right.point == CGPoint(x: 4072, y: 1240))
        #expect(Toss.desktopEntry(LinkEntry(side: .left, height: 0, speed: 0), screens: []) == nil)
    }

    @Test func phoneFlicks() {
        let phone = CGSize(width: 393, height: 852)
        #expect(Toss.phoneExit(point: CGPoint(x: 380, y: 426), velocity: CGVector(dx: 1400, dy: -100), bounds: phone)?.side == .right)
        #expect(Toss.phoneExit(point: CGPoint(x: 200, y: 426), velocity: CGVector(dx: 1400, dy: 0), bounds: phone) == nil)
        #expect(Toss.phoneExit(point: CGPoint(x: 380, y: 426), velocity: CGVector(dx: 300, dy: 0), bounds: phone) == nil)
        let release = Toss.phoneRelease(point: CGPoint(x: 150, y: 213), predicted: CGPoint(x: -120, y: 260),
                                        velocity: CGVector(dx: -1600, dy: 200), bounds: phone)
        #expect(release?.side == .left && abs((release?.height ?? 0) - 0.25) < 0.01)
        #expect(Toss.phoneRelease(point: CGPoint(x: 150, y: 213), predicted: CGPoint(x: 40, y: 260),
                                  velocity: CGVector(dx: -1600, dy: 0), bounds: phone) == nil)
    }
}

@Suite struct JoltTests {
    /// Samples at 60 Hz: `pattern` gives the acceleration over time.
    private func run(_ seconds: Double, _ pattern: (Double) -> Double) -> [JoltDetector.Event] {
        var d = JoltDetector()
        var events: [JoltDetector.Event] = []
        for i in 0..<Int(seconds * 60) {
            let t = Double(i) / 60
            if let e = d.feed(x: pattern(t), at: t) { events.append(e) }
        }
        return events
    }

    @Test func aThrowGoesTheWayTheHandPushed() {
        // Push left hard, then the stop pulls right: one throw, to the left.
        let events = run(1.5) { t in t < 0.1 ? 0 : t < 0.2 ? -3 : t < 0.3 ? 2.6 : 0 }
        #expect(events == [.thrown(.left)])
        #expect(run(1.5) { t in (0.1..<0.2).contains(t) ? 2.5 : 0 } == [.thrown(.right)])
    }

    @Test func shakingIsNotThrowing() {
        let events = run(1.5) { t in t < 0.6 ? 3 * sin(t * 2 * .pi * 8) : 0 }
        #expect(events == [.shaken])
    }

    @Test func gentleMovesAreIgnored() {
        #expect(run(2) { t in 1.2 * sin(t * 6) }.isEmpty)
    }
}

/// A real TLS-PSK handshake over loopback: the same door connects, both ends derive the same binding
/// and messages flow; another door is refused before any message.
@Suite(.serialized) struct LinkChannelTests {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
    }

    private func listen(door: Data, onEvent: @escaping @Sendable (LinkChannel, LinkChannel.Event) -> Void) async throws -> (NWListener, UInt16, Box<[LinkChannel]>) {
        let params = LinkCrypto.parameters(door: door)
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let channels = Box<[LinkChannel]>([])
        listener.newConnectionHandler = { c in
            let ch = LinkChannel(connection: c)
            channels.value.append(ch)
            Task { for await event in ch.events { onEvent(ch, event) } }
            ch.start()
        }
        let port = Box<UInt16?>(nil)
        listener.stateUpdateHandler = { state in if case .ready = state { port.value = listener.port?.rawValue } }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        for _ in 0..<200 where port.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        return (listener, try #require(port.value), channels)
    }

    @Test func sameDoorTalksAndSharesABinding() async throws {
        let door = LinkCrypto.randomKey()
        let hostBinding = Box<Data?>(nil)
        let (listener, port, _) = try await listen(door: door) { ch, event in
            switch event {
            case .ready(let binding): hostBinding.value = binding
            case .frame(let body): if LinkFrame.decode(LinkMessage.self, body) == .ping { ch.send(.pong) }
            case .closed: break
            }
        }
        defer { listener.cancel() }
        let client = LinkChannel(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), door: door)
        client.start()
        var binding: Data?
        var ponged = false
        for await event in client.events {
            switch event {
            case .ready(let b): binding = b; client.send(.ping)
            case .frame(let body): ponged = LinkFrame.decode(LinkMessage.self, body) == .pong
            case .closed: break
            }
            if ponged { break }
        }
        #expect(ponged)
        #expect(binding?.count == LinkCrypto.keyBytes)
        #expect(binding == hostBinding.value)
        client.close()
    }

    @Test func otherDoorIsRefused() async throws {
        let (listener, port, _) = try await listen(door: LinkCrypto.randomKey()) { ch, _ in ch.send(.pong) }
        defer { listener.cancel() }
        let client = LinkChannel(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), door: LinkCrypto.randomKey())
        client.start()
        var ready = false, frames = 0
        var closed: LinkChannel.Close?
        for await event in client.events {
            switch event {
            case .ready: ready = true
            case .frame: frames += 1
            case .closed(let why, _): closed = why
            }
        }
        #expect(!ready && frames == 0)
        #expect(closed == .rejected)
    }

    @Test func aSilentConnectionIsClosed() async throws {
        let door = LinkCrypto.randomKey()
        let (listener, port, _) = try await listen(door: door) { _, _ in }
        defer { listener.cancel() }
        let client = LinkChannel(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: LinkCrypto.parameters(door: door)),
                                 pingInterval: 60, silenceLimit: 0.4)
        client.start()
        var closed: LinkChannel.Close?
        for await event in client.events { if case .closed(let why, _) = event { closed = why } }
        #expect(closed == .unreachable)
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
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(m)).first)
            #expect(LinkFrame.decode(LinkMessage.self, body) == m)
        }
        // A work update from an older Mac (no `from`) still reads.
        let old = Data(#"{"work":{"imp":"1A1A1A1A-0000-4000-8000-00000000F00D","work":{"request":"hi","partial":""}}}"#.utf8)
        #expect(LinkFrame.decode(LinkMessage.self, old) != nil)
    }
}
