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

    @Test func aPhoneReachesItsMacThroughTheHop() async throws {
        let secret = LinkPairing.newSecret()
        let params = LinkTLS.parameters(psk: LinkPairing.psk(for: secret))
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { c in
            let mac = LinkChannel(connection: c)
            mac.onFrame = { if LinkFrame.decode(LinkRequest.self, $0) == .ping { mac.send(LinkUpdate.pong) } }
            mac.start()
        }
        let ready = Flag()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.set() } }
        listener.start(queue: DispatchQueue(label: "live.mac"))
        defer { listener.cancel() }
        for _ in 0..<300 where !ready.value { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(listener.port?.rawValue)

        let hop = try server.hop
        let host = HopHost(address: try #require(HopAddress(hop)), room: Hop.Room(secret: secret), loopbackPort: port)
        host.start()
        defer { host.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let phone = try #require(LinkChannel(hopOf: LinkPairing(mac: UUID(), name: "Mac", secret: secret, hop: hop)))
        let ponged = Flag()
        phone.onFrame = { if LinkFrame.decode(LinkUpdate.self, $0) == .pong { ponged.set() } }
        let closed = Closed()
        phone.onState = { state in
            if state == .ready { phone.send(LinkRequest.ping) }
            if case .closed(let why, let reason) = state { closed.set("\(why) \(reason ?? "")") }
        }
        phone.start()
        for _ in 0..<500 where !ponged.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ponged.value, "phone closed: \(closed.value)")
        #expect(phone.isThroughHop)
        phone.close()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var value: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

private final class Closed: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func set(_ s: String) { lock.withLock { text = s } }
}
