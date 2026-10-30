import Testing
import Foundation
import Network
@testable import ImpKit

@Suite struct LinkFrameTests {
    @Test func roundTripsMessagesAcrossSplitReads() throws {
        let a = LinkRequest.ask(imp: UUID(), text: "Rename the screenshots 🗂️")
        let b = LinkRequest.toss(imp: UUID(), exit: .left, height: 0.25, speed: 2100)
        let bytes = try LinkFrame.encode(a) + LinkFrame.encode(b)
        var framer = LinkFrame()
        var bodies: [Data] = []
        // A byte at a time: frames only come out whole.
        for byte in bytes { bodies += try framer.feed(Data([byte])) }
        #expect(bodies.count == 2)
        #expect(LinkFrame.decode(LinkRequest.self, bodies[0]) == a)
        #expect(LinkFrame.decode(LinkRequest.self, bodies[1]) == b)
    }

    @Test func refusesHugeFrames() {
        var framer = LinkFrame()
        let huge = UInt32(LinkProtocol.maxFrame + 1).bigEndian
        #expect(throws: LinkFrame.Failure.self) { try framer.feed(withUnsafeBytes(of: huge) { Data($0) }) }
    }

    @Test func unknownMessagesAreIgnored() {
        #expect(LinkFrame.decode(LinkUpdate.self, Data(#"{"teleport":{"imp":"x"}}"#.utf8)) == nil)
        #expect(LinkFrame.decode(LinkUpdate.self, Data("garbage".utf8)) == nil)
    }

    @Test func updatesRoundTrip() throws {
        let imp = LinkImp(ImpProfile.imp)
        let turn = LinkTurn(id: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), request: "hi", from: "Pip",
                            reply: "hello", failed: false, steps: ["Ran a command"])
        let beats = [AnimationBeat(duration: 0.4, mood: "happy")]
        for u: LinkUpdate in [.welcome(mac: "Studio", version: 1, imps: [imp], others: []),
                              .arrive(imp: imp, entry: LinkEntry(side: .right, height: 0.3, speed: 1800)),
                              .chat(imp: imp.id, turns: [turn]),
                              .work(imp: imp.id, work: LinkWork(request: "hi", status: "Thinking", partial: "Hel")),
                              .work(imp: imp.id, work: nil),
                              .animate(imp: imp.id, beats: beats),
                              .leave(imp: imp.id)] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(u)).first)
            #expect(LinkFrame.decode(LinkUpdate.self, body) == u)
        }
    }

    @Test func entryCarriesOnTheWayItWent() {
        let e = LinkEntry.after(exit: .left, height: 0.4, speed: 1500)
        #expect(e.side == .right && e.height == 0.4)
        #expect(LinkEntry(side: .left, height: 7, speed: -3) == LinkEntry(side: .left, height: 1, speed: 0))
    }
}

@Suite struct LinkPairingTests {
    @Test func linkRoundTrips() throws {
        let p = LinkPairing(mac: UUID(), name: "Art’s MacBook Pro", secret: LinkPairing.newSecret(), hosts: ["art.local", "100.64.0.7"])
        #expect(p.url.scheme == "implink")
        let back = try #require(LinkPairing(url: p.url))
        #expect(back == p)
        #expect(LinkPairing(string: "  \(p.url.absoluteString)\n") == p)
    }

    @Test func rejectsBrokenLinks() {
        let mac = UUID().uuidString
        #expect(LinkPairing(string: "implink://pair?mac=\(mac)&key=c2hvcnQ") == nil)            // short key
        #expect(LinkPairing(string: "implink://pair?key=\(LinkPairing.base64URL(LinkPairing.newSecret()))") == nil)  // no Mac
        #expect(LinkPairing(string: "https://pair?mac=\(mac)") == nil)
        #expect(LinkPairing(string: "") == nil)
    }

    @Test func keyIsDerivedNotTheSecret() {
        let s = LinkPairing.newSecret()
        #expect(s.count == 32 && s != LinkPairing.newSecret())
        #expect(LinkPairing.psk(for: s) == LinkPairing.psk(for: s))
        #expect(LinkPairing.psk(for: s) != s && LinkPairing.psk(for: s).count == 32)
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

/// A real TLS-PSK handshake over loopback: the same key connects and messages flow; another key
/// is refused before any message.
@Suite(.serialized) struct LinkChannelTests {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T
        init(_ v: T) { _value = v }
        var value: T { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
    }

    private func listen(psk: Data, onFrame: @escaping @Sendable (LinkChannel, Data) -> Void) async throws -> (NWListener, UInt16, Box<[LinkChannel]>) {
        let params = LinkTLS.parameters(psk: psk)
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let channels = Box<[LinkChannel]>([])
        listener.newConnectionHandler = { c in
            let ch = LinkChannel(connection: c)
            ch.onFrame = { onFrame(ch, $0) }
            channels.value.append(ch)
            ch.start()
        }
        let port = Box<UInt16?>(nil)
        listener.stateUpdateHandler = { state in if case .ready = state { port.value = listener.port?.rawValue } }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        for _ in 0..<200 where port.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        return (listener, try #require(port.value), channels)
    }

    @Test func sameKeyTalks() async throws {
        let psk = LinkPairing.psk(for: LinkPairing.newSecret())
        let (listener, port, _) = try await listen(psk: psk) { ch, body in
            if case .hello(_, let name, _)? = LinkFrame.decode(LinkRequest.self, body) {
                ch.send(LinkUpdate.welcome(mac: "Mac of \(name)", version: 1, imps: [], others: []))
            }
        }
        defer { listener.cancel() }
        let got = Box<LinkUpdate?>(nil)
        let client = LinkChannel(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!), psk: psk)
        client.onFrame = { got.value = LinkFrame.decode(LinkUpdate.self, $0) }
        client.onState = { if $0 == .ready { client.send(LinkRequest.hello(device: UUID(), name: "Phone", version: 1)) } }
        client.start()
        for _ in 0..<300 where got.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(got.value == .welcome(mac: "Mac of Phone", version: 1, imps: [], others: []))
        client.close()
    }

    @Test func otherKeyIsRefused() async throws {
        let (listener, port, _) = try await listen(psk: LinkPairing.psk(for: LinkPairing.newSecret())) { ch, _ in
            ch.send(LinkUpdate.pong)
        }
        defer { listener.cancel() }
        let state = Box<LinkChannel.State?>(nil)
        let got = Box(false)
        let client = LinkChannel(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                 psk: LinkPairing.psk(for: LinkPairing.newSecret()))
        client.onFrame = { _ in got.value = true }
        client.onState = { s in
            state.value = s
            if s == .ready { client.send(LinkRequest.ping) }
        }
        client.start()
        for _ in 0..<500 { if case .closed? = state.value { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.value != .ready)
        if case .closed? = state.value {} else { Issue.record("expected the handshake to fail, got \(String(describing: state.value))") }
        #expect(!got.value)
        client.close()
    }
}
