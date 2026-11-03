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
        let pip = BridgeImp(name: "Pip", hue: 0.6, scale: 1.35, traits: ImpTraits(lids: 0.3, horns: -10), mood: "thinking", away: false)
        let r = try #require(JSONSerialization.jsonObject(with: BridgeOutbound.troupe([pip]).encoded()) as? [String: Any])
        let imps = try #require(r["imps"] as? [[String: Any]])
        #expect(r["type"] as? String == "troupe" && imps.count == 1)
        #expect(imps[0]["name"] as? String == "Pip" && imps[0]["hue"] as? Double == 0.6 && imps[0]["mood"] as? String == "thinking")
        #expect(imps[0]["away"] as? Bool == false && imps[0]["scale"] as? Double == 1.35)
        let traits = try #require(imps[0]["traits"] as? [String: Any])
        #expect(traits["lids"] as? Double == 0.3 && traits["horns"] as? Double == -10)
    }

    @Test func statusMapping() throws {
        // Busy on the phone is busy, not asleep.
        #expect(BridgeStatus.of(mood: "idle", hasWork: true, away: true, deviceReachable: true) == .working)
        #expect(BridgeStatus.of(mood: "thinking", hasWork: false, away: true, deviceReachable: true) == .working)
        #expect(BridgeStatus.of(mood: "working", hasWork: false, away: false, deviceReachable: true) == .working)
        #expect(BridgeStatus.of(mood: "idle", hasWork: false, away: true, deviceReachable: true) == .idle)
        #expect(BridgeStatus.of(mood: "happy", hasWork: false, away: false, deviceReachable: true) == .idle)
        #expect(BridgeStatus.of(mood: "sleepy", hasWork: false, away: true, deviceReachable: true) == .asleep)
        #expect(BridgeStatus.of(mood: "idle", hasWork: false, away: true, deviceReachable: false) == .asleep)
        #expect(BridgeStatus.of(mood: "idle", hasWork: false, away: false, deviceReachable: false) == .idle)
        #expect(BridgeStatus.of(mood: "sleepy", hasWork: true, away: true, deviceReachable: false) == .working)
        let imp = BridgeImp(name: "Pip", hue: 0.1, scale: 1, mood: "idle", away: true, status: .working, device: "Ann's iPhone")
        let r = try #require(JSONSerialization.jsonObject(with: BridgeOutbound.troupe([imp]).encoded()) as? [String: Any])
        let o = try #require((r["imps"] as? [[String: Any]])?.first)
        #expect(o["status"] as? String == "working" && o["device"] as? String == "Ann's iPhone")
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
