import Foundation
import Testing
@testable import ImpKit

/// Imps on different devices may share a name. `imp_message` still tells them apart.
@Suite("Talk names")
struct TalkNamesTests {
    private struct Remote: Equatable { let name: String; let device: String }

    @Test("Pip on a Mac, an iPhone and the command line each reach the other two")
    func threePips() {
        let names = TalkNames(sender: "Pip", here: [String](), name: { $0 },
                              away: [Remote(name: "Pip", device: "iPhone"), Remote(name: "Pip", device: "Terminal")],
                              awayName: \.name, place: \.device)
        #expect(names.names == ["Pip@iPhone", "Pip@Terminal"])
        #expect(names.find("pip@terminal").away == Remote(name: "Pip", device: "Terminal"))
        #expect(names.find(" Pip@iPhone ").away?.device == "iPhone")
        #expect(names.find("Pip").here == nil && names.find("Pip").away == nil)
    }

    @Test("Imps here keep their names; one elsewhere called like one here gets its device")
    func hereFirst() {
        let names = TalkNames(sender: "Pip", here: ["Bo"], name: { $0 },
                              away: [Remote(name: "Bo", device: "Studio"), Remote(name: "Mo", device: "Studio")],
                              awayName: \.name, place: \.device)
        #expect(names.names == ["Bo", "Bo@Studio", "Mo"])
        #expect(names.find("bo").here == "Bo")
        #expect(names.find("Bo@Studio").away?.name == "Bo")
    }
}
