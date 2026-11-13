import Foundation
import Testing
@testable import ImpKit

/// Two nodes, each with its own adapter, talking over real sockets on this machine.
@MainActor
final class Watcher {
    var events: [LinkNode.Event] = []

    func attach(to node: LinkNode) {
        node.onEvent = { [weak self] in self?.events.append($0) }
    }

    func wait(seconds: Double = 10, for match: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if match() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return match()
    }

    func heard(_ name: String) -> Bool {
        events.contains { if case .message(.stage(let imps), _) = $0 { imps.contains { $0.imp.name == name } } else { false } }
    }

    var linked: Bool { events.contains { if case .linked = $0 { true } else { false } } }
}

@MainActor
@Suite(.serialized) struct LinkLoopbackTests {
    func node(_ name: String, kind: LinkKind) throws -> LinkNode {
        var options = LinkNode.Options()
        options.port = nil
        options.bonjour = false
        options.watchesNetwork = false
        options.hosts = ["127.0.0.1"]
        options.tick = 0.1
        return try LinkNode(name: name, kind: kind, storage: LinkMemoryStorage(), options: options)
    }

    @Test func twoDevicesJoinWithACodeAndTalk() async throws {
        let mac = try node("Studio", kind: .mac)
        let phone = try node("Pocket", kind: .phone)
        let onMac = Watcher(), onPhone = Watcher()
        onMac.attach(to: mac)
        onPhone.attach(to: phone)
        await mac.start()
        await phone.start()
        defer { mac.stop(); phone.stop() }

        let code = try #require(mac.invite())
        let joined = try await phone.join(code)
        #expect(joined.id == mac.device.id && joined.name == "Studio")
        #expect(await onMac.wait { onMac.linked })
        #expect(mac.links.map(\.device.id) == [phone.device.id])
        #expect(phone.links.map(\.device.id) == [mac.device.id])
        #expect(await onMac.wait { mac.isConnected(phone.device.id) && phone.isConnected(mac.device.id) })

        let pip = LinkImp(id: UUID(), name: "Pip", hue: 0.3, scale: 1, traits: .plain)
        #expect(phone.send(.stage(imps: [LinkStaged(imp: pip, home: phone.device.id)]), to: mac.device.id))
        #expect(await onMac.wait { onMac.heard("Pip") })
    }

    @Test func aCodeForTheDeviceItselfIsRefused() async throws {
        let mac = try node("Studio", kind: .mac)
        await mac.start()
        defer { mac.stop() }
        let own = try #require(mac.invite())
        await #expect(throws: LinkNode.JoinError.self) { try await mac.join(own) }
    }
}

@MainActor
@Suite(.serialized) struct LinkRoutesTests {
    func node() throws -> LinkNode {
        var options = LinkNode.Options()
        options.port = nil
        options.bonjour = false
        options.watchesNetwork = false
        options.hosts = ["127.0.0.1"]
        options.tick = 0.1
        return try LinkNode(name: "Studio", kind: .mac, storage: LinkMemoryStorage(), options: options)
    }

    @Test func aCodeMadeAfterStartHasHostsAndAPort() async throws {
        let mac = try node()
        #expect(!mac.status.isReady)
        await mac.start()
        defer { mac.stop() }
        #expect(mac.status.isReady)
        let url = try #require(mac.invite()).url.absoluteString
        #expect(url.contains("h=127.0.0.1"))
        #expect(url.contains("p=\(try #require(mac.port))"))
    }

    @Test func aSecondStartWaitsForTheFirst() async throws {
        let mac = try node()
        async let first: Void = mac.start()
        async let second: Void = mac.start()
        _ = await (first, second)
        defer { mac.stop() }
        #expect(mac.status.isReady)
        // A start that comes while one is under way returns only when the node is ready.
        let other = try node()
        Task { await other.start() }
        await other.start()
        defer { other.stop() }
        #expect(other.status.routes.port != nil)
    }

    @Test func theHopComesAndGoesWithTheServer() async throws {
        let mac = try node()
        await mac.start()
        defer { mac.stop() }
        #expect(mac.status.routes.hop == nil)
        #expect(try #require(mac.invite()).url.absoluteString.contains("hop=") == false)
        mac.setServer("hop.example.com:4677")
        #expect(mac.status.routes.hop == "hop.example.com:4677")
        #expect(try #require(mac.invite()).url.absoluteString.contains("hop=hop.example.com"))
        mac.setServer(nil)
        #expect(mac.status.routes.hop == nil)
        #expect(try #require(mac.invite()).url.absoluteString.contains("hop=") == false)
    }

    @Test func aLocalNetworkDenialIsDetected() {
        #expect(LinkNode.isPolicyDenied(.dns(-65570)))
        #expect(!LinkNode.isPolicyDenied(.dns(-65537)))
    }

    @Test func anUnreadableBookIsErasedButAnUnavailableOneIsKept() throws {
        let bad = LinkMemoryStorage(Data("{ not json".utf8))
        let opened = try LinkNode.open(name: "Mac", kind: .mac, storage: bad)
        #expect(opened.reset)
        #expect(try bad.load() != Data("{ not json".utf8))

        struct Closed: LinkStorage {
            func load() throws -> Data? { throw CocoaError(.fileReadNoPermission) }
            func save(_ book: Data) throws {}
        }
        #expect(throws: LinkNode.OpenError.self) { try LinkNode.open(name: "Mac", kind: .mac, storage: Closed()) }
    }
}
