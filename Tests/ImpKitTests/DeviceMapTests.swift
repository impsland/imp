import Foundation
import Testing
@testable import ImpKit

@Suite struct DeviceMapTests {
    private let phone = DeviceMap.Peer(id: UUID(), name: "Anna's iPhone", kind: .phone, reach: .direct)
    private let mac = DeviceMap.Peer(id: UUID(), name: "Studio", kind: .mac, reach: .viaServer, isTrusted: true)

    private func imp(_ name: String) -> ImpProfile { ImpProfile(name: name, hue: 0.2, favoriteHue: 0.5, personality: "") }

    @Test func aloneIsOneNode() {
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: "", imps: [imp("Pip")], mcpServers: [])
        #expect(map.nodes.map(\.kind) == [.thisMac])
        #expect(map.channels.isEmpty)
        #expect(map.nodes[0].imps.count == 1)
    }

    @Test func channelsKeepPathStateAndServer() {
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone, mac], server: "imp.example.org", imps: [imp("Pip")], mcpServers: [])
        #expect(map.nodes.map(\.kind) == [.thisMac, .server, .phone, .mac])
        let local = map.channels.first { $0.to == phone.id.uuidString }
        #expect(local?.path == .local && local?.state == .connected && local?.via == nil && local?.server == nil)
        let relay = map.channels.first { $0.to == mac.id.uuidString }
        #expect(relay?.path == .relay && relay?.state == .connected)
        #expect(relay?.via == DeviceMap.serverID && relay?.server == "imp.example.org")
        #expect(map.node(DeviceMap.serverID)?.state == .connected)
        #expect(map.node(mac.id.uuidString)?.isTrusted == true)
    }

    @Test func awayDevicesShowTheirPathOffline() {
        var gone = phone
        gone.reach = .away
        let without = DeviceMap.build(thisMac: "Mac", peers: [gone], server: "", imps: [], mcpServers: [])
        #expect(without.channels[0].path == .local && without.channels[0].state == .offline)
        let with = DeviceMap.build(thisMac: "Mac", peers: [gone], server: "imp.example.org", imps: [], mcpServers: [])
        #expect(with.channels[0].path == .relay && with.channels[0].state == .offline)
        #expect(with.node(DeviceMap.serverID)?.state == .offline)
    }

    @Test func connectingIsItsOwnState() {
        var dialing = phone
        dialing.reach = .connecting
        let map = DeviceMap.build(thisMac: "Mac", peers: [dialing], server: "", imps: [], mcpServers: [])
        #expect(map.channels[0].state == .connecting)
    }

    @Test func badServerIsNoServer() {
        let map = DeviceMap.build(thisMac: "Mac", peers: [mac], server: "not a host!", imps: [], mcpServers: [])
        #expect(map.node(DeviceMap.serverID) == nil)
    }

    @Test func impsAreWhereTheyAre() {
        var away = imp("Away")
        away.awayOn = phone.id
        var stale = imp("Stale")
        stale.awayOn = UUID()      // held by a device that is no longer linked: home
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [imp("Home"), away, stale], mcpServers: [])
        #expect(map.node(phone.id.uuidString)?.imps == [away.id])
        #expect(map.node(DeviceMap.thisMacID)?.imps.count == 2)
    }

    @Test func toolsAndTalk() {
        let files = MCPServerConfig(name: "Files", transport: .stdio, command: "x")
        let off = MCPServerConfig(name: "Off", transport: .stdio, command: "x")
        var disabled = off
        disabled.isEnabled = false
        var a = imp("A")
        a.servers = [files.id, disabled.id]
        var b = imp("B")
        b.setUses(.troupe, false)
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: "", imps: [a, b], mcpServers: [files, disabled])
        let tools = map.imp(a.id)!.tools
        #expect(tools.contains { $0.id == "own.body" })
        #expect(!tools.contains { $0.id == "own.computer" })
        #expect(tools.filter { $0.source == .mcp }.map(\.title) == ["Files"])
        #expect(map.imp(a.id)?.talksTo == [b.id])
        #expect(map.imp(b.id)?.talksTo.isEmpty == true)
        #expect(map.imp(b.id)?.tools.contains { $0.id == "own.troupe" } == false)
    }
}
