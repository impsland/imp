import Foundation
import Testing
@testable import ImpKit
import ImpCore

/// The tool registry: ids, groups and the filter that decides what the model is offered. The shared
/// vectors are in `spec/fixtures/tool-filtering.json`.
@Suite struct ToolRegistryTests {
    private struct Vectors: Decodable {
        struct ID: Decodable { let kind: String; let group: String?; let server: String?; let tool: String; let id: String; let groupID: String }
        struct Tool: Decodable { let id: String?; let name: String; let group: String? }
        struct Case: Decodable { let name: String; let tools: [Tool]; let groupsOff: [String]; let toolsOff: [String]; let offered: [String] }
        let ids: [ID]
        let cases: [Case]
    }

    private static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../spec/fixtures/tool-filtering.json")
        guard let data = try? Data(contentsOf: url), let found = try? JSONDecoder().decode(Vectors.self, from: data) else {
            fatalError("spec/fixtures/tool-filtering.json is missing or unreadable")
        }
        return found
    }()

    private struct Listed: ToolProvider {
        let catalogTools: [CatalogTool]
        func tools() async -> [ToolSpec] { catalogTools.map(\.spec) }
        func catalog() async -> [CatalogTool] { catalogTools }
        func call(_ name: String, arguments: String) async throws -> String { "ran \(name)" }
    }

    private static func catalog(_ tools: [Vectors.Tool]) -> [CatalogTool] {
        tools.map { t in
            CatalogTool(entry: t.id.flatMap { id in t.group.map { ToolEntry(id: id, name: t.name, group: $0) } },
                        spec: ToolSpec(name: t.name, description: ""))
        }
    }

    /// The names Swift dispatches on are exactly the built-in tools of the core registry: neither
    /// side can gain or lose a tool without this failing.
    @Test func theNamesSwiftRunsAreTheCoresBuiltInTools() {
        let swiftNames = Set([
            OwnTools.play, OwnTools.move, OwnTools.speak, OwnTools.status, OwnTools.page, OwnTools.listTriggers,
            OwnTools.addTrigger, OwnTools.removeTrigger, OwnTools.listTools, OwnTools.addTool, OwnTools.addKit, OwnTools.exportKit, OwnTools.removeTool,
            OwnTools.openSettings, OwnTools.message, OwnTools.openFile, OwnTools.makeAnimation, OwnTools.showAnimation, OwnTools.removeAnimation,
            OwnTools.setTraits, OwnTools.showBackground, OwnTools.setBackground,
        ]).union(ComputerTools.all)
        #expect(swiftNames == Set(ToolRegistry.builtIn.map(\.name)))
        #expect(Set(ToolRegistry.builtIn.map(\.group)) == Set(ImpToolGroup.allCases.map { ToolRegistry.ownGroupID($0) }))
    }

    @Test func idVectors() throws {
        for v in Self.vectors.ids {
            if v.kind == "own" {
                let raw = try #require(v.group)
                let group = try #require(ImpToolGroup(rawValue: raw))
                #expect(ToolRegistry.ownID(group, tool: v.tool) == v.id)
                #expect(ToolRegistry.ownGroupID(group) == v.groupID)
            } else {
                let server = try #require(v.server)
                #expect(ToolRegistry.mcpID(server: server, tool: v.tool) == v.id)
                #expect(ToolRegistry.mcpGroupID(server: server) == v.groupID)
            }
        }
    }

    @Test func filteringVectors() async throws {
        for c in Self.vectors.cases {
            let selection = ToolSelection(groupsOff: Set(c.groupsOff), toolsOff: Set(c.toolsOff))
            let tools = Self.catalog(c.tools)
            #expect(ToolRegistry.filter(tools, selection).map(\.spec.name) == c.offered, "\(c.name)")
            let set = ToolSet([Listed(catalogTools: tools)], selection: selection)
            #expect(await set.tools().map(\.name) == c.offered, "\(c.name)")
            for tool in tools {
                let name = tool.spec.name
                if c.offered.contains(name) {
                    #expect(try await set.call(name, arguments: "{}") == "ran \(name)", "\(c.name)")
                } else {
                    await #expect(throws: MCPError.self, "\(c.name): \(name)") { try await set.call(name, arguments: "{}") }
                }
            }
        }
    }

    @Test func refusalIsReadable() async {
        let tools = Self.catalog([.init(id: "own.personality.imp_speak", name: "imp_speak", group: "own.personality")])
        let set = ToolSet([Listed(catalogTools: tools)], selection: ToolSelection(toolsOff: ["own.personality.imp_speak"]))
        do {
            _ = try await set.call("imp_speak", arguments: "{}")
            Issue.record("A switched-off tool ran")
        } catch {
            #expect(error.localizedDescription.contains("switched off"))
        }
        do {
            _ = try await set.call("nothing_like_it", arguments: "{}")
            Issue.record("An unknown tool ran")
        } catch {
            #expect(error.localizedDescription.contains("Unknown tool"))
        }
    }

    @Test func builtInRegistryMatchesTheGroups() {
        let all = ToolRegistry.builtIn
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        for entry in all {
            let group = OwnTools.group(of: entry.name)
            #expect(group != nil, "\(entry.name) has no group")
            #expect(entry.id == ToolRegistry.ownID(group ?? .animations, tool: entry.name))
            #expect(!entry.title.isEmpty)
        }
        for group in ImpToolGroup.allCases { #expect(!ToolRegistry.tools(in: group).isEmpty, "\(group) has no tools") }
    }

    @Test func groupsFollowTheCore() {
        #expect(ImpToolGroup.allCases.map(\.rawValue) == ImpCore.toolGroupNames())
    }

    @Test func everyOfferedOwnToolIsRegistered() {
        let specs = OwnTools.specs(Set(ImpToolGroup.allCases), animations: ["wave"], imps: ["Pip"], browser: true)
            + ComputerTools.specs()
        for spec in specs { #expect(ToolRegistry.entry(named: spec.name) != nil, "\(spec.name) is not in the registry") }
    }

    @Test func profileSelection() {
        var imp = ImpProfile.imp
        #expect(imp.toolSelection.groupsOff == ["own.computer"])
        #expect(imp.toolSelection.toolsOff.isEmpty)
        imp.setUses(.animations, false)
        imp.setUses(.computer, true)
        imp.setUses(tool: ToolRegistry.ownID(.senses, tool: OwnTools.page), false)
        imp.setUses(tool: "mcp.speech.say", false)
        #expect(imp.toolSelection.groupsOff == ["own.animations"])
        #expect(imp.toolSelection.toolsOff == ["own.senses.browser_page", "mcp.speech.say"])
        #expect(!imp.uses(tool: "mcp.speech.say"))
        imp.setUses(tool: "mcp.speech.say", true)
        #expect(imp.uses(tool: "mcp.speech.say"))
    }

    @Test func aGroupThatNoLongerExistsIsSkipped() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpProfile.imp)) as? [String: Any])
        object["ownToolsOn"] = ["computer", "den"]
        let loaded = try JSONDecoder().decode(ImpProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(loaded.uses(.computer))
    }

    @Test func theKitToolsAreInTheToolsGroup() {
        #expect(ToolRegistry.entry(named: "imp_add_kit")?.group == ToolRegistry.ownGroupID(.tools))
        #expect(ToolRegistry.entry(named: "imp_export_kit")?.group == ToolRegistry.ownGroupID(.tools))
        let add = OwnTools.specs([.tools], animations: [], imps: [], browser: false).first { $0.name == OwnTools.addKit }
        #expect(add?.description.contains("This Imp reads kit format \(Kit.format)") == true)
    }

    @Test func savedChoicesCarryOver() throws {
        // A profile saved before single tools could be switched: only group choices.
        var old = ImpProfile.imp
        old.setUses(.senses, false)
        old.setUses(.computer, true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["toolsOff"] = nil
        let loaded = try JSONDecoder().decode(ImpProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!loaded.uses(.senses))
        #expect(loaded.uses(.computer))
        #expect(loaded.disabledTools.isEmpty)
        var changed = loaded
        changed.setUses(tool: "own.personality.imp_speak", false)
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(changed))
        #expect(back.disabledTools == ["own.personality.imp_speak"])
    }
}
