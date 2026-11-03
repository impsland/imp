import Foundation
import Testing
@testable import ImpKit

/// The tool registry: ids, groups and the filter that decides what the model is offered. The shared
/// vectors are in `Tests/Fixtures/tool-filtering.json`.
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
            .appendingPathComponent("Fixtures/tool-filtering.json")
        guard let data = try? Data(contentsOf: url), let found = try? JSONDecoder().decode(Vectors.self, from: data) else {
            fatalError("Tests/Fixtures/tool-filtering.json is missing or unreadable")
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
        let tools = Self.catalog([.init(id: "own.body.imp_speak", name: "imp_speak", group: "own.body")])
        let set = ToolSet([Listed(catalogTools: tools)], selection: ToolSelection(toolsOff: ["own.body.imp_speak"]))
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
            #expect(entry.id == ToolRegistry.ownID(group ?? .body, tool: entry.name))
            #expect(!entry.title.isEmpty)
        }
        for group in ImpToolGroup.allCases { #expect(!ToolRegistry.tools(in: group).isEmpty, "\(group) has no tools") }
    }

    @Test func everyOfferedOwnToolIsRegistered() {
        let specs = OwnTools.specs(Set(ImpToolGroup.allCases), animations: ["wave"], imps: ["Pip"], browser: true)
            + ComputerTools.specs()
        for spec in specs { #expect(ToolRegistry.entry(named: spec.name) != nil, "\(spec.name) is not in the registry") }
    }

    @Test func profileSelection() {
        var imp = ImpProfile.imp
        #expect(imp.toolSelection.groupsOff == ["own.computer", "own.den"])
        #expect(imp.toolSelection.toolsOff.isEmpty)
        imp.setUses(.body, false)
        imp.setUses(.computer, true)
        imp.setUses(tool: ToolRegistry.ownID(.senses, tool: OwnTools.page), false)
        imp.setUses(tool: "mcp.speech.say", false)
        #expect(imp.toolSelection.groupsOff == ["own.body", "own.den"])
        #expect(imp.toolSelection.toolsOff == ["own.senses.browser_page", "mcp.speech.say"])
        #expect(!imp.uses(tool: "mcp.speech.say"))
        imp.setUses(tool: "mcp.speech.say", true)
        #expect(imp.uses(tool: "mcp.speech.say"))
    }

    @Test func savedChoicesCarryOver() throws {
        // A profile saved before single tools could be switched: only group choices.
        var old = ImpProfile.imp
        old.setUses(.senses, false)
        old.setUses(.den, true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["toolsOff"] = nil
        let loaded = try JSONDecoder().decode(ImpProfile.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!loaded.uses(.senses))
        #expect(loaded.uses(.den))
        #expect(loaded.disabledTools.isEmpty)
        var changed = loaded
        changed.setUses(tool: "own.body.imp_speak", false)
        let back = try JSONDecoder().decode(ImpProfile.self, from: JSONEncoder().encode(changed))
        #expect(back.disabledTools == ["own.body.imp_speak"])
    }
}
