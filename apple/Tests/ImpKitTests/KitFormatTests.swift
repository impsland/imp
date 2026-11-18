import Foundation
import Testing
@testable import ImpKit

/// The kit format number and the skills a kit names (spec/PROTOCOL.md, Compatibility and Items).
@Suite struct KitFormatTests {
    private let trigger = #""triggers":[{"name":"t","do": [{"act": "ask", "value": "hi"}],"on": "start"}]"#

    @Test func aMissingFormatIsRead() throws {
        #expect(try Kit.parse("{\(trigger)}").triggers.count == 1)
    }

    @Test func formatOneIsRead() throws {
        #expect(try Kit.parse(#"{"format":1,\#(trigger)}"#).triggers.count == 1)
    }

    @Test func aNewerFormatIsRefusedWithTheSpecsWords() {
        let error = #expect(throws: KitError.self) { try Kit.parse(#"{"format":2,\#(trigger)}"#) }
        #expect(error == .newerFormat(2, 1))
        #expect(error?.errorDescription == "This needs a newer Imp. It is kit format 2, and this Imp reads up to format 1. Update Imp and try again.")
    }

    @Test func aBadFormatIsRefused() {
        for bad in ["0", "1.5", #""1""#, "-3", "null"] {
            #expect(throws: KitError.self, "format \(bad)") { try Kit.parse(#"{"format":\#(bad),\#(trigger)}"#) }
        }
    }

    @Test func writersAlwaysAddTheFormat() throws {
        let kit = try Kit.parse("{\(trigger)}")
        let written = try #require(try? JSONValue(jsonString: kit.json()))
        #expect(written["format"] == .number(Double(Kit.format)))
        #expect(Kit.format == 1)
    }

    @Test func skillsParseAndRoundTrip() throws {
        let text = #"{"format":1,"skills":[{"name":"pdf","source":"anthropics/skills/skills/pdf"},{"name":"x-y","source":"https://example.com/skills/x"}]}"#
        let kit = try Kit.parse(text)
        #expect(kit.skills.map(\.name) == ["pdf", "x-y"])
        #expect(kit.skills[0].command == "npx skills add anthropics/skills/skills/pdf")
        #expect(kit.problems.isEmpty)
        let again = try Kit.parse(kit.json())
        #expect(again.skills == kit.skills)
    }

    @Test func invalidSkillsAreRefused() throws {
        let bad: [(String, String)] = [
            ("pdf", "owner"), ("pdf", "owner/repo name"), ("pdf", "owner/repo;rm -rf"), ("pdf", "owner/repo\"x\""),
            ("pdf", "http://example.com/x"), ("pdf", "-owner/../repo"), ("PDF", "owner/repo"), ("-pdf", "owner/repo"),
            ("", "owner/repo"), ("pdf", ""), ("pdf", "owner/" + String(repeating: "a", count: 200)),
            ("pdf", "https://user:pw@example.com/x"), ("pdf", "$(whoami)/repo"),
        ]
        for (name, source) in bad {
            #expect(throws: KitSkill.Invalid.self, "\(name) \(source)") { try KitSkill(name: name, source: source) }
        }
        let kit = try Kit.parse(#"{"skills":[{"name":"ok","source":"a/b"},{"name":"bad","source":"a b"},{"name":"worse"}]}"#)
        #expect(kit.skills.map(\.name) == ["ok"])
        #expect(kit.problems.count == 2)
    }

    @Test func atMostTwentySkills() throws {
        let many = (0..<25).map { #"{"name":"s\#($0)","source":"o/r\#($0)"}"# }.joined(separator: ",")
        let kit = try Kit.parse(#"{"skills":[\#(many)]}"#)
        #expect(kit.skills.count == Kit.maxSkills)
        #expect(!kit.problems.isEmpty)
    }

    @Test func aKitOfSkillsAloneIsAKit() throws {
        let kit = try Kit.parse(#"{"skills":[{"name":"pdf","source":"a/b"}]}"#)
        #expect(kit.itemCount == 1 && kit.readableSummary.contains("npx skills add a/b"))
    }
}
