// Live Imp server (opt-in): plays this Mac, an iPhone and an Imp against a running Den and Hop.
//   cd server && cargo run -p den & cargo run -p hop &      (see server/README.md)
//   IMP_SERVER=http://localhost:8080 swift test --filter ServerLiveTests

import Foundation
import Network
import Testing
@testable import ImpKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["IMP_SERVER"] != nil), .serialized)
struct ServerLiveTests {
    private var server: ImpServer {
        get throws { try #require(ImpServer(ProcessInfo.processInfo.environment["IMP_SERVER"] ?? "")) }
    }

    @Test func anImpMakesAnAccountAndSharesAnAnimation() async throws {
        let den = DenClient(server: try server)
        let challenge = try await den.challenge()
        let solution = try await Altcha.solve(challenge)
        let handle = "live-\(UUID().uuidString.prefix(8).lowercased())"
        let account = try await den.createAccount(handle: handle, altcha: try Altcha.payload(challenge, solution))
        #expect(account.handle == handle)

        let kit = #"{"imp":3,"name":"Wave","animations":[{"name":"Wave","beats":[{"duration":0.4,"mood":"happy","tilt":10},{"duration":0.4,"mood":"happy","tilt":-10}]}]}"#
        let id = try #require(DenItemID(handle: handle, slug: "wave"))
        #expect(try await den.put(id, summary: "A friendly wave.", tags: ["fun"], kit: kit, token: account.token))
        let item = try await den.item(id)
        #expect(item.kind == "animation")
        #expect(try await den.kit(id).contains("\"Wave\""))
        try await den.countInstall(id)

        try await den.delete(id, token: account.token)
        await #expect(throws: DenError.self) { try await den.item(id) }
    }

    @Test func aGuestReachesItsHostThroughTheHop() async throws {
        let door = LinkCrypto.randomKey()
        let identity = LinkIdentity(name: "Mac", kind: .mac)
        let params = LinkCrypto.parameters(door: door)
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { c in
            let host = LinkChannel(connection: c)
            Task { for await event in host.events { if case .frame(let body) = event, LinkFrame.decode(LinkMessage.self, body) == .ping { host.send(.pong) } } }
            host.start()
        }
        let ready = Flag()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.set() } }
        listener.start(queue: DispatchQueue(label: "live.host"))
        defer { listener.cancel() }
        for _ in 0..<300 where !ready.value { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(listener.port?.rawValue)

        let hopText = try server.hop
        let hop = try #require(HopAddress(hopText))
        let waiting = HopHost(address: hop, credentials: Hop.Credentials(host: identity, door: door), loopbackPort: port)
        waiting.start()
        defer { waiting.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let guest = try #require(LinkChannel(hop: hop, host: identity.publicKey, door: door))
        guest.start()
        var ponged = false
        var closed = ""
        for await event in guest.events {
            switch event {
            case .ready: guest.send(.ping)
            case .frame(let body): ponged = LinkFrame.decode(LinkMessage.self, body) == .pong
            case .closed(let why, let reason): closed = "\(why) \(reason ?? "")"
            }
            if ponged { break }
        }
        #expect(ponged, "guest closed: \(closed)")
        #expect(guest.isThroughHop)
        guest.close()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

