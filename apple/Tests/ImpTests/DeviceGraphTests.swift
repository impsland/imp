import CoreGraphics
import Foundation
import ImpKit
import SwiftFlow
import Testing
@testable import Imp

/// The Devices canvas as data: which nodes and lines `DeviceMap` becomes, where they start, and what a press on each opens.
@Suite struct DeviceGraphTests {
    private let phone = DeviceMap.Peer(id: UUID(), name: "Anna's iPhone", kind: .phone, reach: .direct, isTrusted: true)
    private let studio = DeviceMap.Peer(id: UUID(), name: "Studio", kind: .mac, reach: .viaServer, isTrusted: true)
    private let hop = "hop.example.org:4677"
    private let mac = DeviceMap.thisMacID

    private func imp(_ name: String, awayOn: UUID? = nil) -> ImpProfile {
        var imp = ImpProfile(name: name, hue: 0.2, favoriteHue: 0.5, personality: "")
        imp.awayOn = awayOn
        return imp
    }

    private func visitor(_ name: String, home: UUID) -> LinkStaged {
        LinkStaged(imp: LinkImp(id: UUID(), name: name, hue: 0.7, scale: 1, traits: .plain), home: home)
    }

    private func graph(peers: [DeviceMap.Peer] = [], server: String = "", imps: [ImpProfile] = [], visitors: [LinkStaged] = [],
                       moved: [String: CGPoint] = [:]) -> (DeviceMap, DeviceGraph.Graph) {
        let map = DeviceMap.build(thisMac: "Mac", peers: peers, server: server, imps: imps, mcpServers: [], visitors: visitors)
        return (map, DeviceGraph.build(map, moved: moved))
    }

    @Test func aloneIsThisMacAndTheHopAndNoLines() {
        let (_, graph) = graph()
        #expect(graph.nodes.map(\.id) == [mac, DeviceMap.serverID])
        #expect(graph.edges.isEmpty)
    }

    /// The Hop is a setting, so it is on the canvas whether or not one is set, and says how it stands.
    @Test func theHopIsAlwaysOnTheCanvasWithItsState() throws {
        func standing(_ text: String, peers: [DeviceMap.Peer] = [], server: String? = nil) throws -> HopStanding {
            let map = DeviceMap.build(thisMac: "Mac", peers: peers, server: server ?? "", imps: [], mcpServers: [])
            let graph = DeviceGraph.build(map, hopText: text)
            return try #require(graph.nodes.first { $0.id == DeviceMap.serverID }?.data.hop)
        }
        #expect(try standing("") == .off)
        #expect(try standing("not an address at all ://") == .needsAddress)
        #expect(try standing(hop, server: hop) == .offline)
        #expect(try standing(hop, peers: [studio], server: hop) == .connected)
        // Without the text, the Hop stands as the map says.
        let (_, graph) = graph(peers: [studio], server: hop)
        #expect(graph.nodes.first { $0.id == DeviceMap.serverID }?.data.hop == .connected)
    }

    /// The Hop's state follows the setting: Custom is never off, and a check says more than the map.
    @Test func theHopStandingFollowsTheSetting() {
        var setting = ServerSetting(kind: .hop, text: "")
        #expect(HopStanding(setting, link: .offline) == .off)
        setting.pick(.custom)
        #expect(HopStanding(setting, link: .offline) == .needsAddress)
        setting.edit("not an address ://")
        #expect(HopStanding(setting, link: .offline) == .needsAddress)
        setting.edit(hop)
        #expect(HopStanding(setting, link: .offline) == .offline)
        #expect(HopStanding(setting, link: .connecting) == .connecting)
        #expect(HopStanding(setting, link: .connected) == .connected)
        let address = setting.startCheck()
        #expect(HopStanding(setting, link: .offline) == .connecting)
        setting.finishCheck(address ?? "", reachable: true)
        #expect(HopStanding(setting, link: .offline) == .reachable)
        setting.edit(hop)
        _ = setting.startCheck().map { setting.finishCheck($0, reachable: false) }
        #expect(HopStanding(setting, link: .offline) == .unreachable)
        setting.pick(.off)
        #expect(HopStanding(setting, link: .offline) == .off)
    }

    @Test func aPressOnTheHopOpensItsOwnSheetWhetherOrNotItIsSet() {
        for server in ["", hop] {
            let (_, graph) = graph(server: server)
            #expect(graph.sheet(ofNode: DeviceMap.serverID) == .hop)
        }
        #expect(DevicesSheet.opening(.node(mac)) == .about(.node(mac)))
        #expect(DevicesSheet.opening(.node(DeviceMap.serverID)) == .hop)
    }

    @Test func anImpIsAChildInsideTheDeviceItIsOn() throws {
        let dot = imp("Dot"), bumble = imp("Bumble"), pip = imp("Pip"), fizz = imp("Fizz")
        let (_, graph) = graph(imps: [dot, bumble, pip, fizz])
        let parent = try #require(graph.nodes.first { $0.id == mac })
        let children = graph.nodes.filter { $0.parentId == mac }
        #expect(children.map(\.id) == [dot, bumble, pip, fizz].map { DeviceGraph.impNodeID($0.id, in: mac) })
        for child in children {
            let frame = CGRect(x: child.position.x, y: child.position.y, width: child.width ?? 0, height: child.height ?? 0)
            #expect(CGRect(x: 0, y: 0, width: parent.width ?? 0, height: parent.height ?? 0).contains(frame), "\(child.id) sticks out")
        }
        // Two rows of two (balanced, not three and one), each spanning the full width.
        #expect(children[0].position.y == children[1].position.y && children[2].position.y > children[0].position.y)
        #expect(children.allSatisfy { !$0.draggable } && parent.draggable)
    }

    private func macNode(_ name: String) -> DeviceMap.Node {
        let map = DeviceMap.build(thisMac: name, peers: [], server: "", imps: [], mcpServers: [], visitors: [])
        return map.nodes.first { $0.id == mac }!
    }

    @Test func aSingleChipFillsTheWidthOfItsDevice() throws {
        let (_, graph) = graph(imps: [imp("Pip")])
        let parent = try #require(graph.nodes.first { $0.id == mac })
        let chip = try #require(graph.nodes.first { $0.parentId == mac })
        let inset = DeviceGraph.Metrics.padding
        #expect(chip.position.x == inset && chip.width == (parent.width ?? 0) - 2 * inset)
        #expect(chip.position.y == DeviceGraph.Metrics.header)
        #expect((parent.height ?? 0) - (chip.position.y + (chip.height ?? 0)) == inset, "the same inset below as at the sides")
    }

    @Test func everyRowOfChipsSpansTheInnerWidthEvenly() {
        let inset = DeviceGraph.Metrics.padding, gap = DeviceGraph.Metrics.chipGap
        for count in 1...9 {
            let width = DeviceGraph.box(of: macNode("Mac"), residents: count).width
            let frames = DeviceGraph.chipFrames(count: count, in: width)
            #expect(frames.count == count)
            for (y, row) in Dictionary(grouping: frames, by: \.minY) {
                #expect(row.map(\.minX).min() == inset, "row at \(y) starts at the inset (\(count) chips)")
                #expect(abs((row.map(\.maxX).max() ?? 0) - (width - inset)) < 0.001, "row at \(y) ends at the inset (\(count) chips)")
                #expect(Set(row.map { ($0.width * 100).rounded() }).count == 1, "its chips are equally wide")
                #expect(row.allSatisfy { $0.width >= DeviceGraph.Metrics.chipMinimum - 0.001 })
                for (a, b) in zip(row.sorted { $0.minX < $1.minX }, row.sorted { $0.minX < $1.minX }.dropFirst()) {
                    #expect(abs(b.minX - a.maxX - gap) < 0.001)
                }
            }
        }
    }

    @Test func aDevicesWidthFollowsItsContentWithinALimit() {
        let metrics = DeviceGraph.Metrics.self
        func width(_ title: String, _ residents: Int) -> CGFloat {
            DeviceGraph.box(of: macNode(title), residents: residents).width
        }
        #expect(width("Mac", 0) == metrics.minimumWidth && width("Mac", 1) == metrics.minimumWidth)
        #expect(width("Mac", 3) > width("Mac", 1), "three chips need more room than one")
        #expect(width("Mac", 6) == width("Mac", 3), "never more than three across")
        #expect(width(String(repeating: "W", count: 80), 1) == metrics.maximumWidth, "a long name is cut short, not given endless room")
    }

    @Test func linkedDevicesAreOnTheOtherSideAndNeverOverlap() {
        let imps = [imp("Dot"), imp("Bumble")]
        let (_, graph) = graph(peers: [phone, studio], imps: imps)
        #expect(graph == self.graph(peers: [phone, studio], imps: imps).1, "the same map gives the same graph")
        let devices = graph.devices
        #expect(devices.count == 4, "this Mac, the Hop and the two linked devices")
        let mac = devices.first { $0.id == self.mac }
        #expect(devices.filter { $0.id != self.mac }.allSatisfy { $0.position.x > (mac?.position.x ?? 0) + (mac?.width ?? 0) })
        let frames = devices.map { CGRect(x: $0.position.x, y: $0.position.y, width: $0.width ?? 0, height: $0.height ?? 0) }
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    @Test func aLocalChannelIsOneSolidLine() throws {
        let (_, graph) = graph(peers: [phone])
        let line = try #require(graph.edges.first { $0.target == phone.id.uuidString })
        #expect(line.source == mac && line.data?.look == .local && line.data?.dimmed == false)
        #expect(line.data?.tag?.isEmpty == false)
        guard case .channel(let id)? = line.data?.kind else { Issue.record("not a channel"); return }
        #expect(graph.sheet(ofEdge: line.id) == .about(.channel(id)))
    }

    @Test func aChannelThroughTheHopIsTwoDashedLinesAndTheFirstIsShared() throws {
        let other = DeviceMap.Peer(id: UUID(), name: "Mini", kind: .mac, reach: .viaServer, isTrusted: true)
        let (map, graph) = graph(peers: [studio, other], server: hop)
        let hopNode = try #require(map.nodes.first { $0.kind == .server })
        let toHop = graph.edges.filter { if case .toHop = $0.data?.kind { true } else { false } }
        #expect(toHop.count == 1 && toHop[0].source == mac && toHop[0].target == hopNode.id)
        let fromHop = graph.edges.filter { $0.source == hopNode.id }
        #expect(fromHop.map(\.target).sorted() == [studio.id.uuidString, other.id.uuidString].sorted())
        #expect((toHop + fromHop).allSatisfy { $0.data?.look == .hop })
        // The shared half opens the Hop; the other halves open their channel.
        #expect(graph.sheet(ofEdge: toHop[0].id) == .hop)
        #expect(fromHop.allSatisfy { if case .about(.channel)? = graph.sheet(ofEdge: $0.id) { true } else { false } })
        // The Hop sits between this Mac and the devices when nothing is local.
        let x = { (id: String) in graph.nodes.first { $0.id == id }?.position.x ?? 0 }
        #expect(x(mac) < x(hopNode.id) && x(hopNode.id) < x(studio.id.uuidString))
    }

    @Test func aDeviceThatIsNotConnectedIsDimmed() throws {
        let connecting = DeviceMap.Peer(id: UUID(), name: "Slow", kind: .mac, reach: .connecting)
        let (map, graph) = graph(peers: [phone, connecting])
        let state = { (id: UUID) in map.channels.first { $0.to == id.uuidString }?.state }
        #expect(state(connecting.id) != .connected)
        let line = { (id: UUID) in graph.edges.first { $0.target == id.uuidString }?.data?.dimmed }
        #expect(line(connecting.id) == true && line(phone.id) == false)
    }

    @Test func anImpAwayFromHomeIsTiedToItsHome() throws {
        let away = imp("Dot", awayOn: phone.id), home = imp("Bumble")
        let (_, graph) = graph(peers: [phone], imps: [away, home])
        let tether = try #require(graph.edges.first { if case .tether = $0.data?.kind { true } else { false } })
        #expect(tether.source == DeviceGraph.impNodeID(away.id, in: phone.id.uuidString) && tether.target == mac)
        #expect(tether.data?.look == .tether(hue: away.hue) && tether.zIndex > 0)
        // Only the one away has a tether.
        #expect(graph.edges.filter { $0.data?.isTether == true }.count == 1)
        #expect(graph.sheet(ofEdge: tether.id) == .about(.tether(away.id, in: phone.id.uuidString)))
    }

    /// Tethers use their own sides (chip to the home's bottom or top) while channels use the devices' left and right,
    /// so the two never run along each other; and the side of a tether follows where its home is.
    @Test func tethersAndChannelsAttachAtDifferentPoints() throws {
        let away = imp("Dot", awayOn: phone.id)
        let (_, graph) = graph(peers: [phone], imps: [away])
        let tether = try #require(graph.edges.first { $0.data?.isTether == true })
        let channel = try #require(graph.edges.first { $0.data?.isTether == false })
        #expect(channel.sourceHandle == DeviceGraph.Port.out && channel.targetHandle == DeviceGraph.Port.in)
        #expect(tether.sourceHandle == tether.targetHandle)
        #expect(DeviceGraph.Port.tetherSides.map(DeviceGraph.Port.tether).contains(try #require(tether.targetHandle)))
        #expect(tether.targetHandle != channel.targetHandle && tether.sourceHandle != channel.sourceHandle)
        let chip = try #require(graph.nodes.first { $0.id == tether.source })
        #expect(DeviceGraph.Port.tether(try #require(chip.sourcePosition)) == tether.sourceHandle)

        let device = CGRect(x: 400, y: 100, width: 200, height: 100)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 0, y: 100, width: 200, height: 100)) == .bottom)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 0, y: 0, width: 200, height: 60)) == .top)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 0, y: 300, width: 200, height: 60)) == .bottom)
    }

    /// A line's tag sits beside its middle, on the upper side, and never on the line.
    @Test func aTagSitsClearOfItsLine() {
        let flat = DeviceGraph.tagCenter(source: CGPoint(x: 0, y: 50), target: CGPoint(x: 100, y: 50), mid: CGPoint(x: 50, y: 50), clearance: 16)
        #expect(flat == CGPoint(x: 50, y: 34))
        let backwards = DeviceGraph.tagCenter(source: CGPoint(x: 100, y: 50), target: CGPoint(x: 0, y: 50), mid: CGPoint(x: 50, y: 50), clearance: 16)
        #expect(backwards == CGPoint(x: 50, y: 34))
        let upright = DeviceGraph.tagCenter(source: CGPoint(x: 0, y: 0), target: CGPoint(x: 0, y: 100), mid: CGPoint(x: 0, y: 50), clearance: 16)
        #expect(upright == CGPoint(x: 16, y: 50))
        let slanted = DeviceGraph.tagCenter(source: CGPoint(x: 0, y: 0), target: CGPoint(x: 100, y: 100), mid: CGPoint(x: 50, y: 50), clearance: 16)
        #expect(slanted.y < 50 && slanted.x > 50)
    }

    @Test func aVisitorIsTiedToTheDeviceItThinksOn() throws {
        let noodle = visitor("Noodle", home: phone.id)
        let (_, graph) = graph(peers: [phone], visitors: [noodle])
        let chip = try #require(graph.nodes.first { $0.id == DeviceGraph.impNodeID(noodle.id, in: mac) })
        guard case .imp(let contact, let ours) = chip.data.role else { Issue.record("not an Imp"); return }
        #expect(contact.name == "Noodle" && !ours)
        let tether = try #require(graph.edges.first { $0.source == chip.id })
        #expect(tether.target == phone.id.uuidString)
        #expect(graph.sheet(ofNode: chip.id) == .about(.imp(noodle.id, in: mac)))
    }

    @Test func aDraggedDeviceKeepsItsPlaceAndItsImpsMoveWithIt() throws {
        let dot = imp("Dot")
        let (_, still) = graph(peers: [phone], imps: [dot])
        let there = CGPoint(x: 700, y: -90)
        let (_, dragged) = graph(peers: [phone], imps: [dot], moved: [phone.id.uuidString: there, "gone": there])
        let moved = try #require(dragged.nodes.first { $0.id == phone.id.uuidString })
        #expect(moved.position.x == there.x && moved.position.y == there.y)
        #expect(dragged.nodes.count == still.nodes.count)
        // An Imp's place is relative to its device, so it did not change.
        let chip = DeviceGraph.impNodeID(dot.id, in: mac)
        #expect(dragged.nodes.first { $0.id == chip }?.position == still.nodes.first { $0.id == chip }?.position)
    }

    @Test func aPressOnADeviceAndAnImpOpensTheirSheet() throws {
        let dot = imp("Dot")
        let (map, graph) = graph(peers: [phone], imps: [dot])
        #expect(graph.sheet(ofNode: mac) == .about(.node(mac)))
        #expect(graph.sheet(ofNode: DeviceGraph.impNodeID(dot.id, in: mac)) == .about(.imp(dot.id, in: mac)))
        #expect(graph.sheet(ofNode: "nothing") == nil)
        // Everything on the canvas can be opened from the keyboard list: devices, Imps, lines.
        #expect(graph.openable.count == graph.nodes.count + graph.edges.count)
        // A sheet about something that is gone resolves to nothing.
        #expect(DeviceSelection.node(UUID().uuidString).resolved(in: map) == nil)
        #expect(DeviceSelection.imp(UUID(), in: mac).resolved(in: map) == nil)
        #expect(DeviceSelection.imp(dot.id, in: mac).resolved(in: map) != nil)
    }

    /// SwiftFlow acts on Delete, Cmd-Z and Cmd-A while the canvas has been clicked, so nothing on it may be deletable,
    /// selectable or connectable: those keys then change nothing.
    @Test func nothingOnTheCanvasCanBeDeletedSelectedOrConnected() {
        let dot = imp("Dot", awayOn: phone.id)
        let (_, graph) = graph(peers: [phone, studio], server: hop, imps: [dot], visitors: [visitor("Noodle", home: phone.id)])
        #expect(!graph.nodes.isEmpty && !graph.edges.isEmpty)
        #expect(graph.nodes.allSatisfy { !$0.deletable && !$0.selectable && !$0.connectable })
        #expect(graph.edges.allSatisfy { !$0.deletable })
    }

    @Test func theHopBelowLocalDevicesDoesNotOverlapAnyDevice() throws {
        let (map, graph) = graph(peers: [phone, studio], server: hop, imps: [imp("Dot")])
        let hopNode = try #require(graph.devices.first { $0.id == map.nodes.first { $0.kind == .server }?.id })
        let frame = CGRect(x: hopNode.position.x, y: hopNode.position.y, width: hopNode.width ?? 0, height: hopNode.height ?? 0)
        for other in graph.devices where other.id != hopNode.id {
            #expect(!frame.intersects(CGRect(x: other.position.x, y: other.position.y, width: other.width ?? 0, height: other.height ?? 0)))
        }
    }

    /// Choosing Custom in the Hop's card clears the address; the Hop's sheet must stay open then, whether or not the
    /// map still has anything to say about the Hop, while a sheet about a forgotten device closes.
    @Test func theHopSheetStaysOpenWhenTheHopIsClearedButASheetAboutAGoneDeviceCloses() {
        for server in ["", hop] {
            let (map, _) = graph(peers: [phone], server: server)
            #expect(DevicesSheet.hop.resolved(in: map) == .hop)
            #expect(DevicesSheet.link.resolved(in: map) == .link)
            #expect(DevicesSheet.about(.node(phone.id.uuidString)).resolved(in: map) != nil)
            #expect(DevicesSheet.about(.node(UUID().uuidString)).resolved(in: map) == nil)
        }
        // Opening the Hop from the canvas and clearing it leaves the same sheet.
        let (cleared, _) = graph(server: "")
        #expect(DevicesSheet.opening(.node(DeviceMap.serverID)).resolved(in: cleared) == .hop)
    }
}
