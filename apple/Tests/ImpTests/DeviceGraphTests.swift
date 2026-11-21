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
        LinkStaged(imp: LinkImp(id: UUID(), name: name, hue: 0.7, scale: 1, traits: .plain), home: LinkWho(id: home, name: "Home", kind: .phone))
    }

    private func graph(peers: [DeviceMap.Peer] = [], server: String = "", imps: [ImpProfile] = [], visitors: [LinkStaged] = [],
                       moved: [String: CGPoint] = [:]) -> (DeviceMap, DeviceGraph.Graph) {
        let map = DeviceMap.build(thisMac: "Mac", peers: peers, server: server, imps: imps, mcpServers: [], visitors: visitors)
        return (map, DeviceGraph.build(map, moved: moved))
    }

    @Test func aloneIsThisMacOnly() {
        let (_, graph) = graph()
        #expect(graph.nodes.map(\.id) == [mac])
        #expect(graph.edges.isEmpty)
    }

    /// The Hop is not a node of the canvas, used or not: it is a button in the screen's bar. Its standing is the map's.
    @Test func theHopIsNeverOnTheCanvasButStillSaysHowItStands() {
        let map = DeviceMap.build(thisMac: "Mac", peers: [studio], server: hop, imps: [], mcpServers: [])
        let graph = DeviceGraph.build(map)
        #expect(map.hopInUse)
        #expect(!graph.nodes.contains { $0.id == DeviceMap.serverID })
        #expect(graph.edges.allSatisfy { $0.source != DeviceMap.serverID && $0.target != DeviceMap.serverID })
        #expect(map.hopStanding(text: "") == .off)
        #expect(map.hopStanding(text: "not an address at all ://") == .needsAddress)
        #expect(map.hopStanding(text: hop) == .connected)
        #expect(HopStanding.connected.barTone != HopStanding.off.barTone && HopStanding.unreachable.barTone != HopStanding.off.barTone)
    }

    /// A Hop that is set but that no channel goes through (everything is on the local network) is not drawn.
    @Test func aHopSetButNotUsedIsNotOnTheCanvas() {
        let (map, graph) = graph(peers: [phone], server: hop)
        #expect(!map.hopInUse)
        #expect(!graph.nodes.contains { $0.id == DeviceMap.serverID })
        #expect(graph.edges.allSatisfy { $0.data?.look == .local })
        #expect(graph.devices.count == 2)
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

    @Test func theHopSheetIsReachableWithoutANode() {
        let (_, used) = graph(peers: [studio], server: hop)
        #expect(used.sheet(ofNode: DeviceMap.serverID) == nil, "the Hop is no node: its button in the bar opens it")
        #expect(DevicesSheet.opening(.node(DeviceMap.serverID)) == .hop)
        #expect(DevicesSheet.opening(.node(mac)) == .about(.node(mac)))
        let (map, none) = graph(peers: [phone])
        #expect(map.hop == nil && none.sheet(ofNode: DeviceMap.serverID) == nil)
        #expect(DevicesSheet.hop.resolved(in: map) == .hop)
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

    @Test func linkedDevicesAreOnBothSidesOfThisMacAndNeverOverlap() throws {
        let imps = [imp("Dot"), imp("Bumble")]
        let (_, graph) = graph(peers: [phone, studio], server: hop, imps: imps)
        #expect(graph == self.graph(peers: [phone, studio], server: hop, imps: imps).1, "the same map gives the same graph")
        let devices = graph.devices
        #expect(devices.count == 3, "this Mac and the two linked devices")
        func frame(_ id: String) throws -> CGRect {
            let node = try #require(devices.first { $0.id == id })
            return CGRect(x: node.position.x, y: node.position.y, width: node.width ?? 0, height: node.height ?? 0)
        }
        let centre = try frame(mac), first = try frame(phone.id.uuidString), second = try frame(studio.id.uuidString)
        #expect(first.minX > centre.maxX && second.maxX < centre.minX, "one each side")
        let gap = DeviceGraph.Metrics.columnGap
        #expect(first.minX - centre.maxX >= gap && abs((first.minX - centre.maxX) - (centre.minX - second.maxX)) < 0.001, "the same distance each side")
        let frames = try devices.map { try frame($0.id) }
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    @Test func aSingleLinkedDeviceIsBesideThisMacAtItsHeight() throws {
        let (_, graph) = graph(peers: [phone])
        let centre = try #require(graph.devices.first { $0.id == mac }), other = try #require(graph.devices.first { $0.id == phone.id.uuidString })
        #expect(other.position.x > centre.position.x + (centre.width ?? 0))
        #expect(abs((other.position.y + (other.height ?? 0) / 2) - (centre.position.y + (centre.height ?? 0) / 2)) < 0.001)
    }

    @Test func manyDevicesAreBalancedByHeightOnTheTwoSides() throws {
        let peers = (1...5).map { DeviceMap.Peer(id: UUID(), name: "Device \($0)", kind: .phone, reach: .direct, isTrusted: true) }
        let (_, graph) = graph(peers: peers)
        let centre = try #require(graph.devices.first { $0.id == mac })
        let right = graph.devices.filter { $0.position.x > centre.position.x }, left = graph.devices.filter { $0.position.x < centre.position.x }
        #expect(right.count == 3 && left.count == 2)
    }

    @Test func aLocalChannelIsOneSolidLine() throws {
        let (_, graph) = graph(peers: [phone])
        let line = try #require(graph.edges.first { $0.target == phone.id.uuidString })
        #expect(line.source == mac && line.data?.look == .local && line.data?.dimmed == false)
        #expect(line.interactionWidth == DeviceGraph.Metrics.interactionWidth)
        guard case .channel(let id)? = line.data?.kind else { Issue.record("not a channel"); return }
        #expect(graph.sheet(ofEdge: line.id) == .about(.channel(id)))
    }

    /// Both sides of a card are points for both ends, so a line attaches to the side that faces its device.
    @Test func aChannelAttachesToTheSidesThatFaceEachOther() throws {
        let (_, graph) = graph(peers: [phone, studio], server: hop)
        let right = try #require(graph.edges.first { $0.target == phone.id.uuidString })
        #expect(right.sourceHandle == DeviceGraph.Port.line(.right, .source) && right.targetHandle == DeviceGraph.Port.line(.left, .target))
        let left = try #require(graph.edges.first { $0.target == studio.id.uuidString })
        #expect(left.sourceHandle == DeviceGraph.Port.line(.left, .source) && left.targetHandle == DeviceGraph.Port.line(.right, .target))
        #expect(left.source == mac)
    }

    /// One channel is ONE line between the two devices, dashed through the Hop: it is never split into halves.
    @Test func aChannelThroughTheHopIsOneDashedLineBetweenTheTwoDevices() throws {
        let other = DeviceMap.Peer(id: UUID(), name: "Mini", kind: .mac, reach: .viaServer, isTrusted: true)
        let (map, graph) = graph(peers: [phone, studio, other], server: hop)
        let dashed = graph.edges.filter { $0.data?.look == .hop }
        #expect(dashed.count == 2)
        #expect(Set(dashed.map(\.target)) == [studio.id.uuidString, other.id.uuidString] && dashed.allSatisfy { $0.source == mac })
        #expect(graph.edges.count == 3, "one line each, none to the Hop")
        let local = try #require(graph.edges.first { $0.target == phone.id.uuidString })
        #expect(local.data?.look == .local)
        // A press on a dashed line opens its channel, which shows the Hop as a row.
        for line in dashed {
            guard case .channel(let id)? = line.data?.kind else { Issue.record("not a channel"); continue }
            #expect(graph.sheet(ofEdge: line.id) == .about(.channel(id)))
        }
        #expect(map.hopInUse)
    }

    /// A device known only through another is dimmed on the canvas (its node says it is not linked), hangs on the device
    /// that relays it by a thin dotted line, and has no channel.
    @Test func aDeviceKnownOnlyThroughAnotherIsJoinedToItsRelayByADottedLine() throws {
        let known = DeviceMap.Known(id: UUID(), name: "Beth's iPad", kind: .phone, via: phone.id)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone], server: "", imps: [], mcpServers: [], known: [known])
        let graph = DeviceGraph.build(map)
        let node = try #require(graph.nodes.first { $0.id == known.id.uuidString })
        guard case .device(let device) = node.data.role else { Issue.record("not a device"); return }
        #expect(!device.linked && device.via == phone.id.uuidString)
        let dotted = try #require(graph.edges.first { $0.data?.look == .relay })
        #expect(dotted.source == phone.id.uuidString && dotted.target == known.id.uuidString)
        #expect(graph.edges.filter { $0.target == known.id.uuidString }.count == 1, "no channel of its own")
        #expect(graph.sheet(ofEdge: dotted.id) == .about(.node(known.id.uuidString)))
        #expect(graph.focus(ofEdge: dotted.id) == .device(known.id.uuidString))
        #expect(graph.lit(for: .device(phone.id.uuidString)).contains(dotted.id))
        #expect(map.status(of: device).word != map.status(of: try #require(map.node(phone.id.uuidString))).word)
    }

    /// No text and no plugs on a line: a channel's data is its look, its state and its ends.
    @Test func linesAreFaintUnlessConnectedAndCarryNoPlugs() throws {
        let stranger = DeviceMap.Peer(id: UUID(), name: "Visitor", kind: .mac, reach: .away, isTrusted: false)
        let (_, graph) = graph(peers: [phone, stranger])
        #expect(graph.edges.first { $0.target == phone.id.uuidString }?.data?.dimmed == false)
        #expect(graph.edges.first { $0.target == stranger.id.uuidString }?.data?.dimmed == true)
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
        #expect(tether.hidden, "a tether shows only while its Imp or its device is in focus")
        // Only the one away has a tether.
        #expect(graph.edges.filter { $0.data?.isTether == true }.count == 1)
        // A click on the tether opens that Imp.
        #expect(graph.sheet(ofEdge: tether.id) == .about(.imp(away.id, in: phone.id.uuidString)))
    }

    /// The mark shows only an Imp whose body is not on its home: Dot out on the iPhone, a visitor here, not an Imp at home
    /// on the iPhone.
    @Test func theAwayMarkShowsOnlyWhereTheBodyIsNotAtHome() throws {
        let away = imp("Dot", awayOn: phone.id), home = imp("Bumble")
        let cinder = visitor("Cinder", home: phone.id), noodle = visitor("Noodle", home: phone.id)
        let phoneStaged = DeviceMap.Peer(id: phone.id, name: phone.name, kind: .phone, reach: .direct, isTrusted: true,
                                         stage: [cinder])
        let (_, graph) = graph(peers: [phoneStaged], imps: [away, home], visitors: [noodle])
        func isAway(_ id: UUID, in node: String) throws -> Bool {
            try #require(graph.nodes.first { $0.id == DeviceGraph.impNodeID(id, in: node) }).data.away
        }
        #expect(try isAway(away.id, in: phone.id.uuidString))
        let chip = try #require(graph.nodes.first { $0.id == DeviceGraph.impNodeID(away.id, in: phone.id.uuidString) })
        #expect(chip.data.homeSymbol == "macbook", "an away Imp's chip shows its home device")
        #expect(try #require(graph.nodes.first { $0.id == DeviceGraph.impNodeID(home.id, in: mac) }).data.homeSymbol == nil)
        #expect(try !isAway(home.id, in: mac))
        #expect(try isAway(noodle.imp.id, in: mac))
        #expect(try !isAway(cinder.imp.id, in: phone.id.uuidString), "Cinder is at home on the iPhone")
    }

    /// A channel and a tether attach at different points, so the two never run along each other. The side of a tether
    /// follows where its home is.
    @Test func tethersAndChannelsAttachAtDifferentPoints() throws {
        let away = imp("Dot", awayOn: phone.id)
        let (_, graph) = graph(peers: [phone], imps: [away])
        let tether = try #require(graph.edges.first { $0.data?.isTether == true })
        let channel = try #require(graph.edges.first { $0.data?.isTether == false })
        let leaves = try #require(graph.nodes.first { $0.id == tether.source }?.sourcePosition)
        #expect(tether.targetHandle == DeviceGraph.Port.tether(DeviceGraph.opposite(leaves)), "it arrives at the side facing the chip")
        #expect(DeviceGraph.Port.tetherSides.map(DeviceGraph.Port.tether).contains(try #require(tether.targetHandle)))
        #expect(tether.targetHandle != channel.targetHandle && tether.sourceHandle != channel.sourceHandle)
        let chip = try #require(graph.nodes.first { $0.id == tether.source })
        #expect(DeviceGraph.Port.tether(try #require(chip.sourcePosition)) == tether.sourceHandle)

        let device = CGRect(x: 400, y: 100, width: 200, height: 100)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 0, y: 100, width: 200, height: 100)) == .left, "it never loops under the cards")
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 900, y: 0, width: 200, height: 60)) == .right)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 420, y: 300, width: 100, height: 60)) == .bottom)
        #expect(DeviceGraph.tetherSide(from: device, home: CGRect(x: 420, y: -200, width: 100, height: 60)) == .top)
        #expect(DeviceGraph.facing(from: device, to: CGRect(x: 800, y: 0, width: 10, height: 10)) == .right)
        #expect(DeviceGraph.facing(from: device, to: CGRect(x: 0, y: 0, width: 10, height: 10)) == .left)
        #expect(DeviceGraph.facing(from: device, to: CGRect(x: 450, y: 0, width: 10, height: 10)) == .top)
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
        #expect(graph.openable.count == graph.nodes.count + graph.edges.filter { $0.data?.isTalk == false && $0.data?.isTether == false }.count)
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

    /// Imps that can message each other across devices: Bumble (here) and Dot (out on the iPhone).
    private func talking() -> (DeviceMap, DeviceGraph.Graph, ImpProfile, ImpProfile) {
        let dot = imp("Dot", awayOn: phone.id), bumble = imp("Bumble")
        let (map, graph) = graph(peers: [phone, studio], server: hop, imps: [dot, bumble])
        return (map, graph, dot, bumble)
    }

    @Test func talkLinesAreInTheGraphButHiddenUntilTheirImpIsInFocus() throws {
        let (map, graph, dot, bumble) = talking()
        #expect(map.imp(bumble.id)?.talksTo.contains { $0.id == dot.id } == true)
        let talk = graph.edges.filter { $0.data?.isTalk == true }
        #expect(!talk.isEmpty && talk.allSatisfy(\.hidden))
        let line = try #require(talk.first { if case .talk(let from, let to)? = $0.data?.kind { from == bumble.id && to == dot.id } else { false } })
        #expect(line.source == DeviceGraph.impNodeID(bumble.id, in: mac) && line.target == DeviceGraph.impNodeID(dot.id, in: phone.id.uuidString))
        let shown = graph.shown(in: .imp(bumble.id, in: mac))
        #expect(shown.edges.first { $0.id == line.id }?.hidden == false)
        #expect(shown.edges.filter { $0.data?.isTalk == true && !$0.hidden }.allSatisfy { if case .talk(let from, _)? = $0.data?.kind { from == bumble.id } else { false } })
        #expect(shown.nodes == graph.nodes, "focus changes no place")
        #expect(graph.shown(in: nil) == graph)
        #expect(graph.sheet(ofEdge: line.id) == .about(.imp(bumble.id, in: mac)))
    }

    /// Tethers are hidden by default and appear when their Imp or one of their two devices is in focus.
    @Test func tethersAppearOnlyInFocus() throws {
        let (map, graph, dot, bumble) = talking()
        let phoneID = phone.id.uuidString
        let tether = try #require(graph.edges.first { $0.data?.isTether == true })
        #expect(tether.hidden && graph.edges.filter { $0.data?.isTether == true }.allSatisfy(\.hidden))
        func hidden(_ focus: DeviceGraph.Focus?) -> Bool { graph.shown(in: focus).edges.first { $0.id == tether.id }?.hidden ?? true }
        #expect(!hidden(.imp(dot.id, in: phoneID)) && !hidden(.device(phoneID)) && !hidden(.device(mac)))
        #expect(hidden(.imp(bumble.id, in: mac)) && hidden(.device(studio.id.uuidString)) && hidden(nil))
        let channel = try #require(map.channels.first { $0.to == phoneID })
        #expect(hidden(.channel(channel.id)))
        #expect(graph.shown(in: .device(phoneID)).nodes == graph.nodes, "focus changes no place")
    }

    @Test func anImpInFocusLightsItsBodyHomeChannelAndTether() throws {
        let (_, graph, dot, _) = talking()
        let phoneID = phone.id.uuidString
        let lit = graph.lit(for: .imp(dot.id, in: phoneID))
        let chip = DeviceGraph.impNodeID(dot.id, in: phoneID)
        #expect(lit.isSuperset(of: [chip, phoneID, mac, "tether/\(phoneID)/\(dot.id.uuidString)"]))
        let channel = try #require(graph.edges.first { $0.target == phoneID && $0.data?.isTether == false })
        #expect(lit.contains(channel.id), "the channel between its body and its home")
        #expect(!lit.contains(studio.id.uuidString) && !lit.contains(DeviceMap.serverID))
        // Bumble talks to Dot: its talk line and Dot's chip are lit when Bumble is.
        let talk = try #require(graph.edges.first { $0.data?.isTalk == true })
        let litTalker = graph.lit(for: try #require(graph.focus(ofEdge: talk.id)))
        #expect(litTalker.contains(talk.id) && litTalker.contains(talk.target) && litTalker.contains(phoneID))
    }

    @Test func aDeviceInFocusLightsItsImpsAndLinesAndAnotherLeavesTheRestDim() throws {
        let (_, graph, dot, _) = talking()
        let studioID = studio.id.uuidString, phoneID = phone.id.uuidString
        let lit = graph.lit(for: .device(studioID))
        let studioLine = try #require(graph.edges.first { $0.target == studioID })
        #expect(lit.contains(studioID) && lit.contains(mac) && lit.contains(studioLine.id))
        #expect(!lit.contains(phoneID) && !lit.contains(DeviceGraph.impNodeID(dot.id, in: phoneID)))
        let phoneLit = graph.lit(for: .device(phoneID))
        #expect(phoneLit.contains(DeviceGraph.impNodeID(dot.id, in: phoneID)) && phoneLit.contains("tether/\(phoneID)/\(dot.id.uuidString)"))
        #expect(!phoneLit.contains(studioID))
    }

    @Test func aChannelInFocusLightsItsEndsTheHopAndWhoTravelsOverIt() throws {
        let (map, graph, dot, _) = talking()
        let phoneChannel = try #require(map.channels.first { $0.to == phone.id.uuidString })
        let lit = graph.lit(for: .channel(phoneChannel.id))
        let phoneID = phone.id.uuidString
        #expect(lit.isSuperset(of: [mac, phoneID, DeviceGraph.impNodeID(dot.id, in: phoneID), "tether/\(phoneID)/\(dot.id.uuidString)", "channel/\(phoneChannel.id)"]))
        #expect(!lit.contains(DeviceMap.serverID))
        let hopChannel = try #require(map.channels.first { $0.to == studio.id.uuidString })
        let viaHop = graph.lit(for: .channel(hopChannel.id))
        #expect(viaHop.isSuperset(of: [mac, studio.id.uuidString, "channel/\(hopChannel.id)"]) && !viaHop.contains(phoneID))
    }

    @Test func focusComesFromASheetsSelectionAndAPressOnTheGraph() throws {
        let (map, graph, dot, _) = talking()
        let phoneID = phone.id.uuidString
        #expect(DeviceGraph.Focus(DevicesSheet.about(.imp(dot.id, in: phoneID))) == .imp(dot.id, in: phoneID))
        #expect(DeviceGraph.Focus(DevicesSheet.hop) == nil, "the Hop is no node")
        #expect(DeviceGraph.Focus(DevicesSheet.link) == nil)
        #expect(graph.focus(ofNode: DeviceGraph.impNodeID(dot.id, in: phoneID)) == .imp(dot.id, in: phoneID))
        #expect(graph.focus(ofNode: phoneID) == .device(phoneID))
        let channel = try #require(map.channels.first { $0.to == phoneID })
        #expect(graph.focus(ofEdge: "channel/\(channel.id)") == .channel(channel.id))
        #expect(graph.focus(ofEdge: "tether/\(phoneID)/\(dot.id.uuidString)") == .imp(dot.id, in: phoneID))
    }

    @Test func noDeviceOverlapsAnother() throws {
        let known = DeviceMap.Known(id: UUID(), name: "Beth's iPad", kind: .phone, via: phone.id)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone, studio], server: hop, imps: [imp("Dot")], mcpServers: [], known: [known])
        let devices = DeviceGraph.build(map).devices
        let frames = devices.map { CGRect(x: $0.position.x, y: $0.position.y, width: $0.width ?? 0, height: $0.height ?? 0) }
        #expect(frames.count == 4)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    /// Choosing Custom in the Hop's card clears the address. The Hop's sheet must stay open then, whether or not the
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
