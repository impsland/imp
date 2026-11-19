import Testing
@testable import ImpDesign

@Suite("Imp Settings sections")
struct ImpSettingTests {
    @Test("The rail reads Brain, Personality, Look, Animations, Triggers, Tools, Computer")
    func order() {
        #expect(ImpSetting.allCases == [.brain, .personality, .look, .animations, .triggers, .tools, .computer])
    }

    @Test("A page name from a tool or a link finds its section")
    func pageNames() {
        #expect(ImpSetting(page: " Looks ") == .look)
        #expect(ImpSetting(page: "computer") == .computer)
        #expect(ImpSetting(page: "nope") == nil)
    }

    @Test("Every section has its own picture")
    func symbols() {
        #expect(Set(ImpSetting.allCases.map(\.symbol)).count == ImpSetting.allCases.count)
    }
}
