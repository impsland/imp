// Live Imp Link (opt-in): plays an iPhone against a running Imp on this Mac, over loopback.
//   IMP_LINK_SECRET=<base64 secret from …/Imp/iphone.json> IMP_LINK_DEVICE=<phone id> IMP_LINK_IMP=<an Imp on that phone>
//   swift test --filter LinkLiveTests
// The Imp must be on that phone (`awayOn`). Its model isn't needed: a failed answer is still an answer.

import Foundation
import Network
import Testing
@testable import ImpKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["IMP_LINK_SECRET"] != nil), .serialized)
struct LinkLiveTests {
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var _updates: [LinkUpdate] = []
        var ready = false
        func add(_ u: LinkUpdate) { lock.withLock { _updates.append(u) } }
        var updates: [LinkUpdate] { lock.withLock { _updates } }
    }

    private func wait(_ inbox: Inbox, seconds: Double = 10, until done: ([LinkUpdate]) -> Bool) async throws -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done(inbox.updates) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return done(inbox.updates)
    }

    @Test func aPhoneTalksToTheMac() async throws {
        let env = ProcessInfo.processInfo.environment
        let secret = try #require(env["IMP_LINK_SECRET"].flatMap { Data(base64Encoded: $0) })
        let device = try #require(env["IMP_LINK_DEVICE"].flatMap(UUID.init(uuidString:)))
        let imp = try #require(env["IMP_LINK_IMP"].flatMap(UUID.init(uuidString:)))
        let inbox = Inbox()
        let channel = LinkChannel(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: LinkProtocol.port)!),
                                  psk: LinkPairing.psk(for: secret))
        channel.onFrame = { body in if let u = LinkFrame.decode(LinkUpdate.self, body) { inbox.add(u) } }
        channel.onState = { state in
            print("link:", state)
            if state == .ready { channel.send(LinkRequest.hello(device: device, name: "Test iPhone", version: LinkProtocol.version)) }
        }
        channel.start()
        defer { channel.close() }

        // Welcome, with the Imp on this phone, then what it's up to.
        let welcomed = try await wait(inbox) { us in
            us.contains { if case .welcome(_, _, let imps, _) = $0 { return imps.contains { $0.id == imp } }; return false }
        }
        #expect(welcomed, "updates: \(inbox.updates)")
        #expect(try await wait(inbox) { us in us.contains { if case .chat(let id, _) = $0 { return id == imp }; return false } })

        // Ask it something: the turn lands in its chat (answered, or failed for want of a model).
        let words = "Ping from the link test \(UUID().uuidString.prefix(6))"
        channel.send(LinkRequest.ask(imp: imp, text: words))
        let answered = try await wait(inbox, seconds: 60) { us in
            us.contains { if case .chat(let id, let turns) = $0 { return id == imp && turns.contains { $0.request == words } }; return false }
        }
        #expect(answered)
        let worked = inbox.updates.contains { if case .work(let id, let w) = $0 { return id == imp && w?.request == words }; return false }
        print("saw work in progress:", worked)

        // Ping, and a toss back to the Mac: it says the Imp has left the phone.
        channel.send(LinkRequest.ping)
        #expect(try await wait(inbox) { $0.contains(.pong) })
        channel.send(LinkRequest.toss(imp: imp, exit: .right, height: 0.4, speed: 1800))
        #expect(try await wait(inbox) { $0.contains(.leave(imp: imp)) })
        for u in inbox.updates { print("got:", String(describing: u).prefix(160)) }
    }
}
