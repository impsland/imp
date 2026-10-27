import Testing
import Foundation
@testable import ImpKit

@Suite struct BridgeTests {
    @Test func decodesInbound() {
        #expect(BridgeInbound.decode(Data(#"{"type":"hello","browser":"Arc","version":1}"#.utf8)) == .hello(browser: "Arc", version: 1))
        #expect(BridgeInbound.decode(Data(#"{"type":"page","url":"https://a.b/","title":"T"}"#.utf8)) == .page(url: "https://a.b/", title: "T"))
        #expect(BridgeInbound.decode(Data(#"{"type":"located","id":"1","rect":{"x":1,"y":2,"width":3,"height":4}}"#.utf8))
                == .located(id: "1", rect: BridgeRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(BridgeInbound.decode(Data(#"{"type":"located","id":"1","rect":null}"#.utf8)) == .located(id: "1", rect: nil))
        #expect(BridgeInbound.decode(Data(#"{"type":"text","id":"2","text":"hi"}"#.utf8)) == .text(id: "2", text: "hi"))
    }

    @Test func rejectsGarbage() {
        #expect(BridgeInbound.decode(Data("nope".utf8)) == nil)
        #expect(BridgeInbound.decode(Data(#"{"type":"explode"}"#.utf8)) == nil)
        #expect(BridgeInbound.decode(Data(#"{"type":"page"}"#.utf8)) == nil)
    }

    @Test func encodesOutbound() throws {
        let d = BridgeOutbound.locate(id: "7", query: "Add to Cart").encoded()
        let o = try #require(JSONSerialization.jsonObject(with: d) as? [String: Any])
        #expect(o["type"] as? String == "locate" && o["id"] as? String == "7" && o["query"] as? String == "Add to Cart")
        let t = try #require(JSONSerialization.jsonObject(with: BridgeOutbound.text(id: "8", limit: 50).encoded()) as? [String: Any])
        #expect(t["type"] as? String == "text" && t["limit"] as? Int == 50)
    }

    @Test func originAllowList() {
        #expect(Bridge.isAllowedOrigin("chrome-extension://abcdef"))
        #expect(Bridge.isAllowedOrigin("moz-extension://x"))
        #expect(Bridge.isAllowedOrigin("safari-web-extension://x"))
        #expect(!Bridge.isAllowedOrigin("https://example.com"))
        #expect(!Bridge.isAllowedOrigin("http://chrome-extension://x"))
        #expect(!Bridge.isAllowedOrigin(nil))
    }

    @Test func flipsCoordinates() {
        let r = Bridge.cocoaRect(BridgeRect(x: 100, y: 200, width: 50, height: 20), primaryScreenHeight: 1000)
        #expect(r == CGRect(x: 100, y: 780, width: 50, height: 20))
    }
}
