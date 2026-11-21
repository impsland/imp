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

    @Test func theHopIsThereOnlyWhenSetAndUsedWhenAChannelGoesThroughIt() {
        let none = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [], mcpServers: [])
        #expect(none.hop == nil && !none.hopInUse)
        #expect(none.hopStanding(text: "") == .off)
        let set = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "imp.example.org", imps: [], mcpServers: [])
        #expect(!set.hopInUse, "set, but every channel is local")
        let used = DeviceMap.build(thisMac: "Mac", peers: [phone, mac], server: "imp.example.org", imps: [], mcpServers: [])
        #expect(used.hop?.kind == .server && used.hopInUse)
    }

    @Test func travellersAreThisMacsImpsOnTheFarDeviceAndItsImpsVisitingHere() throws {
        var out = imp("Dot")
        out.awayOn = phone.id
        let visitor = LinkStaged(imp: LinkImp(id: UUID(), name: "Noodle", hue: 0.4, scale: 1, traits: .plain), home: LinkWho(id: phone.id, name: phone.name, kind: phone.kind))
        let other = LinkStaged(imp: LinkImp(id: UUID(), name: "Stranger", hue: 0.6, scale: 1, traits: .plain), home: LinkWho(id: UUID(), name: "Elsewhere", kind: .mac))
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [out, imp("Pip")], mcpServers: [], visitors: [visitor, other])
        let channel = try #require(map.channels.first)
        let travellers = map.travellers(of: channel)
        #expect(travellers.out.map(\.name) == ["Dot"])
        #expect(travellers.in.map(\.name) == ["Noodle"])
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
        let elsewhere = UUID()
        stale.awayOn = elsewhere   // held by a device this Mac is not linked with: it is there, never shown at home
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [imp("Home"), away, stale], mcpServers: [])
        #expect(map.node(phone.id.uuidString)?.imps == [away.id])
        #expect(map.node(DeviceMap.thisMacID)?.imps.count == 1)
        let stranger = map.node(elsewhere.uuidString)
        #expect(stranger?.imps == [stale.id])
        #expect(stranger?.linked == false)
    }

    @Test func aHolderKnownThroughAnotherShowsItsNameAndKind() {
        var out = imp("Out")
        let holder = UUID()
        out.awayOn = holder
        let known = DeviceMap.Known(id: holder, name: "Anna's iPhone", kind: .phone, via: phone.id)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [out], mcpServers: [], known: [known])
        let node = map.node(holder.uuidString)
        #expect(node?.name == "Anna's iPhone")
        #expect(node?.kind == .phone)
        #expect(node?.linked == false)
        #expect(node?.via == phone.id.uuidString)
        #expect(node?.imps == [out.id])
    }

    /// Dot is out on the iPhone, where Cinder and Noodle live. It can message Bumble at home and
    /// every Imp on the phone's screen. Bumble, at home with no visitors, can message Dot only.
    @Test func anImpAwayTalksToTheImpsOnTheScreenItIsOn() {
        var dot = imp("Dot")
        dot.awayOn = phone.id
        let bumble = imp("Bumble")
        let cinder = LinkImp(id: UUID(), name: "Cinder", hue: 0.1, scale: 1, traits: .plain)
        let noodle = LinkImp(id: UUID(), name: "Noodle", hue: 0.6, scale: 1, traits: .plain)
        var onPhone = phone
        onPhone.stage = [LinkStaged(imp: cinder, home: LinkWho(id: phone.id, name: phone.name, kind: phone.kind)), LinkStaged(imp: noodle, home: LinkWho(id: phone.id, name: phone.name, kind: phone.kind)),
                         LinkStaged(imp: LinkImp(dot), home: LinkWho(id: UUID(), name: "Elsewhere", kind: .mac))]
        let map = DeviceMap.build(thisMac: "Mac", peers: [onPhone], server: "", imps: [dot, bumble], mcpServers: [])
        #expect(map.imp(dot.id)?.talksTo.map(\.name) == ["Bumble", "Cinder", "Noodle"])
        #expect(map.imp(dot.id)?.talksTo.last?.location == phone.id.uuidString)
        #expect(map.imp(bumble.id)?.talksTo.map(\.name) == ["Dot"])
        #expect(map.residents(of: phone.id.uuidString).map(\.name) == ["Dot", "Cinder", "Noodle"])
    }

    /// A visitor on this Mac's desktop is on the same screen as the Mac's Imps at home.
    @Test func anImpAtHomeTalksToTheVisitorsHere() {
        let bumble = imp("Bumble")
        let cinder = LinkImp(id: UUID(), name: "Cinder", hue: 0.1, scale: 1, traits: .plain)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [bumble], mcpServers: [],
                                  visitors: [LinkStaged(imp: cinder, home: LinkWho(id: phone.id, name: phone.name, kind: phone.kind))])
        #expect(map.imp(bumble.id)?.talksTo.map(\.name) == ["Cinder"])
        #expect(map.residents(of: DeviceMap.thisMacID).map(\.name) == ["Bumble", "Cinder"])
    }

    /// A relay channel names the Hop's address as set, a local one the device's first known route. The nodes list
    /// every route.
    @Test func channelsSayTheAddressTheyGoThrough() {
        var local = phone
        local.routes = LinkRoutes(hosts: ["studio.local", "fe80::1"], port: 47824)
        let map = DeviceMap.build(thisMac: "Mac", thisRoutes: LinkRoutes(hosts: ["10.0.0.2"], port: 47825), peers: [local, mac],
                                  server: " IMP.example.org:4000 ", imps: [], mcpServers: [])
        #expect(map.channels.first { $0.to == phone.id.uuidString }?.address == "studio.local:47824")
        #expect(map.channels.first { $0.to == mac.id.uuidString }?.address == "imp.example.org:4000")
        #expect(map.node(DeviceMap.thisMacID)?.addresses == ["10.0.0.2:47825"])
        #expect(map.node(phone.id.uuidString)?.addresses == ["studio.local:47824", "[fe80::1]:47824"])
        #expect(map.node(DeviceMap.serverID)?.addresses == ["imp.example.org:4000"])
        let bare = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [], mcpServers: [])
        #expect(bare.channels[0].address == nil && bare.node(DeviceMap.thisMacID)?.addresses == [])
    }

    /// Imps know the node they think on: this Mac for its own, the linked device for the ones hatched there,
    /// the device's own node for one we aren't linked with.
    @Test func impsKnowTheirHomeNode() {
        let bumble = imp("Bumble")
        let cinder = LinkImp(id: UUID(), name: "Cinder", hue: 0.1, scale: 1, traits: .plain)
        let stranger = LinkImp(id: UUID(), name: "Stranger", hue: 0.3, scale: 1, traits: .plain)
        let far = LinkWho(id: UUID(), name: "Elsewhere", kind: .mac)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [bumble], mcpServers: [],
                                  visitors: [LinkStaged(imp: cinder, home: LinkWho(id: phone.id, name: phone.name, kind: phone.kind)), LinkStaged(imp: stranger, home: far)])
        let here = map.residents(of: DeviceMap.thisMacID)
        #expect(here.map(\.home) == [DeviceMap.thisMacID, phone.id.uuidString, far.id.uuidString])
        #expect(map.imp(bumble.id)?.talksTo.map(\.home) == [phone.id.uuidString, far.id.uuidString])
    }

    @Test func toolsAndTalk() {
        let files = MCPServerConfig(name: "Files", transport: .stdio, command: "x")
        let off = MCPServerConfig(name: "Off", transport: .stdio, command: "x")
        var disabled = off
        disabled.isEnabled = false
        var a = imp("A")
        a.servers = [files.id, disabled.id]
        var b = imp("B")
        b.setUses(.personality, false)
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: "", imps: [a, b], mcpServers: [files, disabled])
        let tools = map.imp(a.id)!.tools
        #expect(tools.contains { $0.id == "own.personality" })
        #expect(!tools.contains { $0.id == "own.computer" })
        #expect(tools.filter { $0.source == .mcp }.map(\.title) == ["Files"])
        #expect(map.imp(a.id)?.talksTo.map(\.id) == [b.id])
        #expect(map.imp(b.id)?.talksTo.isEmpty == true)
        #expect(map.imp(b.id)?.tools.contains { $0.id == "own.personality" } == false)
    }
}
