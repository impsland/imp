import Foundation
import Testing
@testable import ImpKit

@Suite struct SettingsMapTests {
    private let pip = Sleeper(id: UUID(), name: "Pip")
    private let moss = Sleeper(id: UUID(), name: "Moss")

    private func node(_ kind: SettingsNode.Kind, _ state: SettingsNode.State, name: String = "x", sleeping: [Sleeper] = []) -> SettingsNode {
        SettingsNode(id: "\(kind)-\(name)", kind: kind, name: name, state: state, sleeping: sleeping)
    }

    @Test func nothingToFixIsEmpty() {
        let nodes = [node(.thisDevice, .ready), node(.brains, .ready), node(.tools, .off),
                     node(.hop, .ready), node(.desktop, .ready, name: "Studio")]
        #expect(SettingsMap.attention(nodes).isEmpty)
    }

    @Test func eachProblemBecomesOneItemThatOpensItsGroup() {
        let nodes = [node(.thisDevice, .ready, sleeping: [pip, moss]), node(.brains, .needsSetup),
                     node(.hop, .needsSetup), node(.phone, .offline, name: "Anna's iPhone")]
        let items = SettingsMap.attention(nodes)
        #expect(items.map(\.reason) == [.noBrains, .noBrain(pip), .noBrain(moss), .hopNotSet, .deviceOffline("Anna's iPhone")])
        #expect(items.map(\.group) == [.brains, .brains, .brains, .devices, .devices])
    }

    @Test func offToolsAndAnOffDeviceAreNotProblems() {
        #expect(SettingsMap.attention([node(.tools, .off), node(.desktop, .off, name: "Studio")]).isEmpty)
    }

    @Test func nothingSetUpListsBrainsAndHop() {
        var prefs = ImpPreferences()
        prefs.hop = ""
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: "", imps: prefs.imps, mcpServers: [])
        let nodes = SettingsMap.nodes(prefs: prefs, map: map)
        #expect(nodes.first { $0.kind == .brains }?.state == .needsSetup)
        #expect(nodes.first { $0.kind == .hop }?.state == .off)
        #expect(nodes.first { $0.kind == .thisDevice }?.sleeping.count == prefs.imps.count)
    }

    @Test func aHopOnThisComputerIsNamedAsSuch() {
        var prefs = ImpPreferences()
        prefs.hop = ServerKind.hop.localAddress
        let map = DeviceMap.build(thisMac: "Mac", peers: [], server: prefs.hop, imps: prefs.imps, mcpServers: [])
        let hop = SettingsMap.nodes(prefs: prefs, map: map).first { $0.kind == .hop }
        #expect(hop?.isLocal == true && hop?.state == .ready)
    }

    @Test func peersCarryReachAndToolAccess() {
        var prefs = ImpPreferences()
        prefs.ai.add(Service(name: "S", baseURL: "http://localhost:1/v1", model: "m"))
        let phone = DeviceMap.Peer(id: UUID(), name: "Anna's iPhone", kind: .phone, reach: .away)
        let mac = DeviceMap.Peer(id: UUID(), name: "Studio", kind: .mac, reach: .direct, isTrusted: true)
        let map = DeviceMap.build(thisMac: "Mac", peers: [phone, mac], server: "", imps: prefs.imps, mcpServers: [])
        let nodes = SettingsMap.nodes(prefs: prefs, map: map)
        let anna = nodes.first { $0.name == "Anna's iPhone" }
        let studio = nodes.first { $0.name == "Studio" }
        #expect(anna?.kind == .phone && anna?.state == .offline && anna?.seen == false)
        #expect(studio?.kind == .desktop && studio?.state == .ready && studio?.seen == true && studio?.toolsHere == true)
        #expect(nodes.first { $0.kind == .brains }?.state == .ready)
        #expect(nodes.first { $0.kind == .thisDevice }?.sleeping.isEmpty == true)
    }

    @Test func theRailListsEverySectionOnceWithNoOverview() {
        let all = SettingsGroup.allCases
        #expect(all == [.app, .bubble, .talking, .brains, .devices, .sharing, .animations, .privacy, .backup])
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty })
        #expect(SettingsGroup(rawValue: "overview") == nil)
    }

    @Test func theHopBelongsToDevices() {
        #expect(node(.hop, .off).group == .devices)
        #expect(node(.desktop, .offline).group == .devices && node(.phone, .offline).group == .devices)
        #expect(node(.brains, .ready).group == .brains && node(.tools, .off).group == .brains)
        #expect(SettingID.devicesHop.page == .devices)
    }

    @Test func eachSectionShowsOnlyWhatIsFixedThere() {
        let nodes = [node(.thisDevice, .ready, sleeping: [pip]), node(.brains, .ready),
                     node(.hop, .needsSetup), node(.phone, .offline, name: "Anna's iPhone")]
        #expect(SettingsMap.attention(nodes, in: .brains).map(\.reason) == [.noBrain(pip)])
        #expect(SettingsMap.attention(nodes, in: .devices).map(\.reason) == [.hopNotSet, .deviceOffline("Anna's iPhone")])
        for group in SettingsGroup.allCases where ![.brains, .devices].contains(group) {
            #expect(SettingsMap.attention(nodes, in: group).isEmpty, "\(group)")
        }
        // Nothing is lost: every item shows in exactly one section.
        #expect(SettingsGroup.allCases.flatMap { SettingsMap.attention(nodes, in: $0) }.count == SettingsMap.attention(nodes).count)
    }

    @Test func aSectionIsMarkedOnlyWhenSomethingInItNeedsAFix() {
        let nodes = [node(.thisDevice, .ready, sleeping: [pip]), node(.brains, .ready), node(.hop, .ready)]
        let marked = SettingsMap.attentionGroups(SettingsMap.attention(nodes))
        #expect(marked == [.brains])
        #expect(SettingsMap.attentionGroups([]).isEmpty)
    }

    @Test func whiteOnColouredControlsIsTheDefaultAndTheChoiceIsKept() throws {
        var prefs = ImpPreferences()
        #expect(prefs.controlInk == .white)
        prefs.controlInk = .black
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.controlInk == .black)
        #expect(ControlInk.allCases == [.white, .black])
    }
}
