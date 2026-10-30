import CryptoKit
import Foundation
import Network
import Testing
@testable import ImpKit

private func hex(_ s: String) -> Data {
    Data(stride(from: 0, to: s.count, by: 2).map { i in
        UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)!
    })
}

@Suite struct HopWireTests {
    /// Derived outside Swift (HMAC-SHA256 by Python, the Ed25519 public key by OpenSSL) from the secret 00 01 … 1f.
    static let secret = Data(0..<32)
    static let room = hex("95fef6334029267c9a6bacf6cb65df423d1cc6d219449f9cd0aa455c56a0b6e2")

    @Test func theRoomIsDerivedFromTheSecret() {
        #expect(Hop.Room(secret: Self.secret).id == Self.room)
        #expect(Hop.Room(secret: Data(repeating: 7, count: 32)).id != Self.room)
    }

    @Test func helloIsFortyBytes() {
        let room = Hop.Room(secret: Self.secret)
        let mac = room.hello(as: .mac)
        #expect(mac.count == 40)
        #expect(Array(mac.prefix(6)) == Array("IMPHOP".utf8))
        #expect(mac[6] == 0x01 && mac[7] == 0x01)
        #expect(mac.suffix(32) == Self.room)
        #expect(room.hello(as: .phone)[7] == 0x02)
    }

    @Test func theProofSignsTheNonceForOneRole() throws {
        let room = Hop.Room(secret: Self.secret)
        let nonce = Data((0..<32).map { UInt8(255 - $0) })
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Self.room)
        let proof = try room.proof(as: .phone, nonce: nonce)
        #expect(proof.count == Hop.proofBytes)
        let message = Data("imp-hop/1".utf8) + [0x02] + nonce
        #expect(Hop.Room.proofMessage(as: .phone, nonce: nonce) == message)
        #expect(key.isValidSignature(proof, for: message))
        #expect(!key.isValidSignature(proof, for: Hop.Room.proofMessage(as: .mac, nonce: nonce)))
        #expect(!key.isValidSignature(proof, for: Hop.Room.proofMessage(as: .phone, nonce: Data(nonce.reversed()))))
    }

    @Test func addressesAreHostAndPort() {
        #expect(HopAddress("Imp.Example.org:4677")?.text == "imp.example.org:4677")
        #expect(HopAddress("127.0.0.1:1")?.port == 1)
        #expect(HopAddress("host:65535")?.port == 65535)
        for bad in ["", "host", "host:", ":4677", "host:0", "host:65536", "host:-1", "host:+80", "host:80a", "a b:80", "ho/st:80",
                    "host..x:80", "-x.org:80", "x-.org:80", "user@host:80", "[::1]:80", String(repeating: "a", count: 256) + ":80"] {
            #expect(HopAddress(bad) == nil, "\(bad)")
        }
        #expect(HopAddress(String(repeating: "a", count: 63) + ".org:80") != nil)
    }

    @Test func pairingCarriesTheHop() throws {
        let p = LinkPairing(mac: UUID(), name: "Mac", secret: LinkPairing.newSecret(), hosts: ["a.local"], hop: "imp.example.org:4677")
        #expect(LinkPairing(url: p.url) == p)
        #expect(p.url.absoluteString.contains("hop=imp.example.org:4677"))
        var none = p
        none.hop = nil
        #expect(LinkPairing(url: none.url)?.hop == nil)
        #expect(!none.url.absoluteString.contains("hop="))
        for bad in ["nope", "host:0", "host:99999", "a b:80", "x/y:80", String(repeating: "a", count: 300) + ":80"] {
            var c = URLComponents(url: p.url, resolvingAgainstBaseURL: false)!
            c.queryItems = c.queryItems!.filter { $0.name != "hop" } + [URLQueryItem(name: "hop", value: bad)]
            #expect(LinkPairing(url: c.url!) == nil, "\(bad)")
        }
    }

    @Test func aRouteUpdateRoundTrips() throws {
        for u: LinkUpdate in [.route(hop: "imp.example.org:4677"), .route(hop: nil)] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(u)).first)
            #expect(LinkFrame.decode(LinkUpdate.self, body) == u)
        }
    }
}

// MARK: Over loopback

private extension NWConnection {
    func readSome() async throws -> Data? {
        try await withCheckedThrowingContinuation { k in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { k.resume(throwing: error) } else if let data, !data.isEmpty { k.resume(returning: data) }
                else if complete { k.resume(returning: nil) } else { k.resume(returning: Data()) }
            }
        }
    }

    func readExactly(_ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { k in
            receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
                if let error { k.resume(throwing: error) } else if let data, data.count == n { k.resume(returning: data) }
                else { k.resume(throwing: NWError.posix(.ECONNRESET)) }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { k.resume(throwing: error) } else { k.resume() }
            })
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
}

private func startListener(_ params: NWParameters, _ handle: @escaping @Sendable (NWConnection) -> Void) async throws -> (NWListener, UInt16) {
    params.requiredInterfaceType = .loopback
    let listener = try NWListener(using: params, on: .any)
    listener.newConnectionHandler = handle
    let port = Box<UInt16?>(nil)
    listener.stateUpdateHandler = { if case .ready = $0 { port.value = listener.port?.rawValue } }
    listener.start(queue: DispatchQueue(label: "test.listener"))
    for _ in 0..<300 where port.value == nil { try await Task.sleep(for: .milliseconds(10)) }
    return (listener, try #require(port.value))
}

/// A stand-in for the relay: checks hello and proof like the real one, then splices a phone to the
/// Mac waiting in the same room. `answers` scripts the status given to the next connections.
private final class FakeHop: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Data: NWConnection] = [:]
    private var script: [UInt8]
    private var _seen: [String] = []
    let queue = DispatchQueue(label: "test.hop")

    init(answers: [UInt8] = []) { script = answers }

    var seen: [String] { lock.withLock { _seen } }

    func handle(_ c: NWConnection) {
        c.start(queue: queue)
        Task { try? await serve(c) }
    }

    private func serve(_ c: NWConnection) async throws {
        let hello = try await c.readExactly(40)
        guard hello.prefix(6) == Data("IMPHOP".utf8), hello[6] == 1, let role = Hop.Role(rawValue: hello[7]),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.suffix(32)) else { return c.cancel() }
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await c.write(nonce)
        let proof = try await c.readExactly(64)
        guard key.isValidSignature(proof, for: Hop.Room.proofMessage(as: role, nonce: nonce)) else {
            try await c.write(Data([Hop.Status.rejected.rawValue]))
            return c.cancel()
        }
        let room = Data(hello.suffix(32))
        lock.withLock { _seen.append(role == .mac ? "mac" : "phone") }
        if let status = lock.withLock({ script.isEmpty ? nil : script.removeFirst() }) {
            try await c.write(Data([status]))
            return c.cancel()
        }
        switch role {
        case .mac:
            lock.withLock { waiters[room] = c }
        case .phone:
            var mac: NWConnection?
            for _ in 0..<10 where mac == nil {
                mac = lock.withLock { waiters.removeValue(forKey: room) }
                if mac == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard let mac else {
                try await c.write(Data([Hop.Status.nobody.rawValue]))
                return c.cancel()
            }
            try await mac.write(Data([Hop.Status.go.rawValue]))
            try await c.write(Data([Hop.Status.go.rawValue]))
            Task { await Self.pump(mac, c) }
            Task { await Self.pump(c, mac) }
        }
    }

    private static func pump(_ from: NWConnection, _ to: NWConnection) async {
        while let data = try? await from.readSome() { if !data.isEmpty { try? await to.write(data) } }
        from.cancel()
        to.cancel()
    }
}

@Suite(.serialized) struct HopLinkTests {
    /// The Mac: a TLS-PSK Link listener that answers a ping with a pong.
    private func mac(secret: Data) async throws -> (NWListener, UInt16) {
        try await startListener(LinkTLS.parameters(psk: LinkPairing.psk(for: secret))) { c in
            let ch = LinkChannel(connection: c)
            ch.onFrame = { body in if LinkFrame.decode(LinkRequest.self, body) == .ping { ch.send(LinkUpdate.pong) } }
            ch.start()
        }
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aPhoneReachesTheMacThroughTheHop() async throws {
        let secret = LinkPairing.newSecret()
        let relay = FakeHop()
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        let (macListener, macPort) = try await mac(secret: secret)
        defer { hopListener.cancel(); macListener.cancel() }
        let host = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")), room: Hop.Room(secret: secret), loopbackPort: macPort)
        host.start()
        defer { host.stop() }

        let pairing = LinkPairing(mac: UUID(), name: "Mac", secret: secret, hop: "127.0.0.1:\(hopPort)")
        let phone = try #require(LinkChannel(hopOf: pairing))
        let ponged = Box(false)
        phone.onFrame = { if LinkFrame.decode(LinkUpdate.self, $0) == .pong { ponged.value = true } }
        phone.onState = { if $0 == .ready { phone.send(LinkRequest.ping) } }
        phone.start()
        try await wait { ponged.value }
        #expect(ponged.value)
        #expect(phone.isThroughHop)
        phone.close()

        // The Mac went back to waiting for the next phone, and a second phone gets through too.
        let again = try #require(LinkChannel(hopOf: pairing))
        let second = Box(false)
        again.onFrame = { if LinkFrame.decode(LinkUpdate.self, $0) == .pong { second.value = true } }
        again.onState = { if $0 == .ready { again.send(LinkRequest.ping) } }
        again.start()
        try await wait { second.value }
        #expect(second.value)
        again.close()
        #expect(relay.seen.filter { $0 == "mac" }.count == 3)
    }

    @Test func aMacKeepsWaitingAfterNobodyCame() async throws {
        let secret = LinkPairing.newSecret()
        let relay = FakeHop(answers: [Hop.Status.nobody.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        // The first wait ends at once (0x03), which is too fast to trust: it backs off a second, then waits again.
        let host = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")), room: Hop.Room(secret: secret), loopbackPort: 1)
        host.start()
        defer { host.stop() }
        try await wait { relay.seen.count >= 2 }
        #expect(relay.seen == ["mac", "mac"])
    }

    @Test func aRejectedMacStopsAndSaysSo() async throws {
        let secret = LinkPairing.newSecret()
        let relay = FakeHop(answers: [Hop.Status.rejected.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let host = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")), room: Hop.Room(secret: secret), loopbackPort: 1)
        let rejected = Box(false)
        host.onRejected = { rejected.value = true }
        host.start()
        defer { host.stop() }
        try await wait { rejected.value }
        #expect(rejected.value)
    }

    @Test func aPhoneWithNobodyWaitingGivesUpForNow() async throws {
        let relay = FakeHop()
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let phone = try #require(LinkChannel(hopOf: LinkPairing(mac: UUID(), name: "Mac", secret: LinkPairing.newSecret(), hop: "127.0.0.1:\(hopPort)")))
        let state = Box<LinkChannel.State?>(nil)
        phone.onState = { state.value = $0 }
        phone.start()
        try await wait { state.value != nil }
        guard case .closed(let why, _)? = state.value else { Issue.record("expected a close, got \(String(describing: state.value))"); return }
        #expect(why == .unreachable)
    }

    @Test func aPhoneTheHopRejectsIsToldSo() async throws {
        let relay = FakeHop(answers: [Hop.Status.rejected.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let phone = try #require(LinkChannel(hopOf: LinkPairing(mac: UUID(), name: "Mac", secret: LinkPairing.newSecret(), hop: "127.0.0.1:\(hopPort)")))
        let state = Box<LinkChannel.State?>(nil)
        phone.onState = { state.value = $0 }
        phone.start()
        try await wait { state.value != nil }
        guard case .closed(let why, _)? = state.value else { Issue.record("expected a close, got \(String(describing: state.value))"); return }
        #expect(why == .hopRefused)
    }
}
