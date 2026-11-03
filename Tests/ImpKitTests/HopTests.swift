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
    /// Derived outside Swift (HMAC-SHA256 by Python, Ed25519 keys and signatures by OpenSSL) from the
    /// device key 00 01 … 1f, the door key 20 21 … 3f and the nonce ff fe … e0.
    static let seed = Data(0..<32)
    static let door = Data(32..<64)
    static let nonce = Data((0..<32).map { UInt8(255 - $0) })
    static let room = hex("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
    static let gate = hex("ca0a3f20b1b05c7ecb5c9a39b9ee6a362ff1f8d125d7c21a62dc8f35d1f01529")
    static let hostProof = hex("a456894bad16d773df90133350363ffb7e1b9c4692e7c0b858525be4df379365861f6ea97135de1399ac92f051a5c5abc568d1a0cbdd97c1ac31888912f6c208")
    static let guestProof = hex("b5fae1f5dd8ff35f626cb9b50ce60d4cd54eea5ca78b1a2fbae0ecac7dc99245a52fac3cbba994b7376ff45c5289e44802a33f6ff62023a23d3556630bcf0600")
    static let psk = hex("9c074aecc7a312b11d922a6ab4242d7268a715063af26bbf8cc32c6ccab8b2df")

    var identity: LinkIdentity { LinkIdentity(id: UUID(), name: "Mac", kind: .mac, seed: Self.seed)! }

    @Test func theRoomIsTheHostsPublicKeyAndTheGateComesFromTheDoor() {
        #expect(identity.publicKey == Self.room)
        #expect(LinkCrypto.gate(door: Self.door) == Self.gate)
        #expect(LinkCrypto.gate(door: Data(repeating: 7, count: 32)) != Self.gate)
        #expect(LinkCrypto.psk(door: Self.door) == Self.psk)
        #expect(LinkCrypto.psk(door: Self.door) != Self.door)
    }

    @Test func helloIsSeventyTwoBytes() {
        let host = Hop.Credentials(host: identity, door: Self.door)
        let guest = Hop.Credentials(guestOf: Self.room, door: Self.door)
        #expect(host.hello.count == 72 && guest.hello.count == 72 && Hop.helloBytes == 72)
        #expect(Array(host.hello.prefix(6)) == Array("IMPHOP".utf8))
        #expect(host.hello[6] == 0x02 && host.hello[7] == 0x01)
        #expect(guest.hello[6] == 0x02 && guest.hello[7] == 0x02)
        #expect(host.hello[8..<40] == Self.room && host.hello.suffix(32) == Self.gate)
        #expect(guest.hello[8..<40] == Self.room && guest.hello.suffix(32) == Self.gate)
    }

    @Test func proofsMatchTheFixedVectors() throws {
        let host = Hop.Credentials(host: identity, door: Self.door)
        let guest = Hop.Credentials(guestOf: Self.room, door: Self.door)
        // CryptoKit's signatures differ from run to run, so ours are checked against the fixed
        // keys and messages, and the OpenSSL ones below must check out too.
        let roomKey = try Curve25519.Signing.PublicKey(rawRepresentation: Self.room)
        let gateKey = try Curve25519.Signing.PublicKey(rawRepresentation: Self.gate)
        let hostMessage = Data("imp-hop/2".utf8) + [0x01] + Self.nonce + Self.gate
        let guestMessage = Data("imp-hop/2".utf8) + [0x02] + Self.nonce + Self.room
        let mine = try host.proof(nonce: Self.nonce), yours = try guest.proof(nonce: Self.nonce)
        #expect(mine.count == 64 && yours.count == 64)
        #expect(roomKey.isValidSignature(mine, for: hostMessage) && gateKey.isValidSignature(yours, for: guestMessage))
        #expect(roomKey.isValidSignature(Self.hostProof, for: hostMessage) && gateKey.isValidSignature(Self.guestProof, for: guestMessage))
        #expect(Hop.proofMessage(role: .host, nonce: Self.nonce, room: Self.room, gate: Self.gate) == Data("imp-hop/2".utf8) + [0x01] + Self.nonce + Self.gate)
        #expect(Hop.proofMessage(role: .guest, nonce: Self.nonce, room: Self.room, gate: Self.gate) == Data("imp-hop/2".utf8) + [0x02] + Self.nonce + Self.room)
    }

    @Test func eachProofIsGoodForOneRoleOneNonceOneKey() throws {
        let roomKey = try Curve25519.Signing.PublicKey(rawRepresentation: Self.room)
        let gateKey = try Curve25519.Signing.PublicKey(rawRepresentation: Self.gate)
        let hostMessage = Hop.proofMessage(role: .host, nonce: Self.nonce, room: Self.room, gate: Self.gate)
        let guestMessage = Hop.proofMessage(role: .guest, nonce: Self.nonce, room: Self.room, gate: Self.gate)
        #expect(roomKey.isValidSignature(Self.hostProof, for: hostMessage))
        #expect(!roomKey.isValidSignature(Self.hostProof, for: guestMessage))
        #expect(gateKey.isValidSignature(Self.guestProof, for: guestMessage))
        #expect(!gateKey.isValidSignature(Self.guestProof, for: hostMessage))
        // A guest can't sign for the room, and the host's key isn't the gate.
        #expect(!roomKey.isValidSignature(Self.guestProof, for: guestMessage))
        #expect(!gateKey.isValidSignature(Self.hostProof, for: hostMessage))
        let other = Hop.proofMessage(role: .guest, nonce: Data(Self.nonce.reversed()), room: Self.room, gate: Self.gate)
        #expect(!gateKey.isValidSignature(Self.guestProof, for: other))
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

    @Test func anInviteCarriesTheHop() throws {
        let invite = LinkInvite(device: identity.device, door: Self.door, invite: Data(repeating: 9, count: 32),
                                routes: try #require(LinkRoutes(checking: ["a.local"], port: LinkProtocol.port, hop: "imp.example.org:4677")))
        #expect(LinkInvite(url: invite.url) == invite)
        #expect(invite.url.absoluteString.contains("hop=imp.example.org:4677"))
        var none = invite
        none.routes.hop = nil
        #expect(LinkInvite(url: none.url)?.routes.hop == nil)
        #expect(!none.url.absoluteString.contains("hop="))
        for bad in ["nope", "host:0", "host:99999", "a b:80", "x/y:80", String(repeating: "a", count: 300) + ":80"] {
            var c = URLComponents(url: invite.url, resolvingAgainstBaseURL: false)!
            c.queryItems = c.queryItems!.filter { $0.name != "hop" } + [URLQueryItem(name: "hop", value: bad)]
            #expect(LinkInvite(url: c.url!) == nil, "\(bad)")
        }
    }

    @Test func aRouteUpdateRoundTrips() throws {
        let door = Data(repeating: 3, count: 32)
        for m: LinkMessage in [.routes(door: door, routes: LinkRoutes(hosts: ["a.local"], hop: "imp.example.org:4677")),
                               .routes(door: door, routes: .none)] {
            var framer = LinkFrame()
            let body = try #require(try framer.feed(LinkFrame.encode(m)).first)
            #expect(LinkFrame.decode(LinkMessage.self, body) == m)
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

/// A stand-in for the relay: checks hello and proof like the real one, then splices a guest to the
/// host waiting in the same room. `answers` scripts the status given to the next connections.
private final class FakeHop: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Data: (conn: NWConnection, gate: Data)] = [:]
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
        let hello = try await c.readExactly(Hop.helloBytes)
        let room = Data(hello[8..<40]), gate = Data(hello.suffix(32))
        guard hello.prefix(6) == Data("IMPHOP".utf8), hello[6] == 2, let role = Hop.Role(rawValue: hello[7]),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: role == .host ? room : gate) else { return c.cancel() }
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await c.write(nonce)
        let proof = try await c.readExactly(Hop.proofBytes)
        guard key.isValidSignature(proof, for: Hop.proofMessage(role: role, nonce: nonce, room: room, gate: gate)) else {
            try await c.write(Data([Hop.Status.rejected.rawValue]))
            return c.cancel()
        }
        lock.withLock { _seen.append(role == .host ? "host" : "guest") }
        if let status = lock.withLock({ script.isEmpty ? nil : script.removeFirst() }) {
            try await c.write(Data([status]))
            return c.cancel()
        }
        switch role {
        case .host:
            lock.withLock { waiters[room] = (c, gate) }
        case .guest:
            var host: NWConnection?
            for _ in 0..<10 where host == nil {
                // A guest with another gate than the host vouched for doesn't get in.
                host = lock.withLock { waiters[room]?.gate == gate ? waiters.removeValue(forKey: room)?.conn : nil }
                if host == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            guard let host else {
                try await c.write(Data([Hop.Status.nobody.rawValue]))
                return c.cancel()
            }
            try await host.write(Data([Hop.Status.go.rawValue]))
            try await c.write(Data([Hop.Status.go.rawValue]))
            Task { await Self.pump(host, c) }
            Task { await Self.pump(c, host) }
        }
    }

    private static func pump(_ from: NWConnection, _ to: NWConnection) async {
        while let data = try? await from.readSome() { if !data.isEmpty { try? await to.write(data) } }
        from.cancel()
        to.cancel()
    }
}

@Suite(.serialized) struct HopLinkTests {
    /// The host: a TLS-PSK Link listener that answers a ping with a pong.
    private func host(door: Data) async throws -> (NWListener, UInt16) {
        try await startListener(LinkCrypto.parameters(door: door)) { c in
            let channel = LinkChannel(connection: c)
            Task {
                for await event in channel.events {
                    if case .frame(let body) = event, LinkFrame.decode(LinkMessage.self, body) == .ping { channel.send(.pong) }
                }
            }
            channel.start()
        }
    }

    private func wait(_ done: () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Pings through `channel` and says whether a pong came back.
    private func pings(_ channel: LinkChannel) async -> Bool {
        for await event in channel.events {
            switch event {
            case .ready: channel.send(.ping)
            case .frame(let body): if LinkFrame.decode(LinkMessage.self, body) == .pong { return true }
            case .closed: return false
            }
        }
        return false
    }

    @Test func aGuestReachesTheHostThroughTheHop() async throws {
        let door = LinkCrypto.randomKey()
        let identity = LinkIdentity(name: "Mac", kind: .mac)
        let relay = FakeHop()
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        let (hostListener, hostPort) = try await host(door: door)
        defer { hopListener.cancel(); hostListener.cancel() }
        let waiting = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")),
                              credentials: Hop.Credentials(host: identity, door: door), loopbackPort: hostPort)
        waiting.start()
        defer { waiting.stop() }

        let address = try #require(HopAddress("127.0.0.1:\(hopPort)"))
        let guest = try #require(LinkChannel(hop: address, host: identity.publicKey, door: door))
        guest.start()
        #expect(await pings(guest))
        #expect(guest.isThroughHop)
        guest.close()

        // The host went back to waiting for the next guest, and a second guest gets through too.
        let again = try #require(LinkChannel(hop: address, host: identity.publicKey, door: door))
        again.start()
        #expect(await pings(again))
        again.close()
        // The host's third wait is registered on its own time, after the second guest is through.
        try await wait { relay.seen.filter { $0 == "host" }.count >= 3 }
        #expect(relay.seen.filter { $0 == "host" }.count == 3)
    }

    @Test func aHostKeepsWaitingAfterNobodyCame() async throws {
        let relay = FakeHop(answers: [Hop.Status.nobody.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        // The first wait ends at once (0x03), which is too fast to trust: it backs off a second, then waits again.
        let host = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")),
                           credentials: Hop.Credentials(host: LinkIdentity(name: "Mac", kind: .mac), door: LinkCrypto.randomKey()), loopbackPort: 1)
        host.start()
        defer { host.stop() }
        try await wait { relay.seen.count >= 2 }
        #expect(relay.seen == ["host", "host"])
    }

    @Test func aRejectedHostStopsAndSaysSo() async throws {
        let relay = FakeHop(answers: [Hop.Status.rejected.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let host = HopHost(address: try #require(HopAddress("127.0.0.1:\(hopPort)")),
                           credentials: Hop.Credentials(host: LinkIdentity(name: "Mac", kind: .mac), door: LinkCrypto.randomKey()), loopbackPort: 1)
        let rejected = Box(false)
        host.onRejected = { rejected.value = true }
        host.start()
        defer { host.stop() }
        try await wait { rejected.value }
        #expect(rejected.value)
    }

    private func closeReason(of channel: LinkChannel) async -> LinkChannel.Close? {
        channel.start()
        for await event in channel.events { if case .closed(let why, _) = event { return why } }
        return nil
    }

    @Test func aGuestWithNobodyWaitingGivesUpForNow() async throws {
        let relay = FakeHop()
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let address = try #require(HopAddress("127.0.0.1:\(hopPort)"))
        let guest = try #require(LinkChannel(hop: address, host: LinkIdentity(name: "Mac", kind: .mac).publicKey, door: LinkCrypto.randomKey()))
        #expect(await closeReason(of: guest) == .unreachable)
    }

    @Test func aGuestWithAnotherDoorFindsNobody() async throws {
        let door = LinkCrypto.randomKey()
        let identity = LinkIdentity(name: "Mac", kind: .mac)
        let relay = FakeHop()
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let address = try #require(HopAddress("127.0.0.1:\(hopPort)"))
        let waiting = HopHost(address: address, credentials: Hop.Credentials(host: identity, door: door), loopbackPort: 1)
        waiting.start()
        defer { waiting.stop() }
        try await wait { relay.seen.contains("host") }
        let guest = try #require(LinkChannel(hop: address, host: identity.publicKey, door: LinkCrypto.randomKey()))
        #expect(await closeReason(of: guest) == .unreachable)
    }

    @Test func aGuestTheHopRejectsIsToldSo() async throws {
        let relay = FakeHop(answers: [Hop.Status.rejected.rawValue])
        let (hopListener, hopPort) = try await startListener(.tcp, relay.handle)
        defer { hopListener.cancel() }
        let address = try #require(HopAddress("127.0.0.1:\(hopPort)"))
        let guest = try #require(LinkChannel(hop: address, host: LinkIdentity(name: "Mac", kind: .mac).publicKey, door: LinkCrypto.randomKey()))
        #expect(await closeReason(of: guest) == .hopRefused)
    }
}
