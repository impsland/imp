import Foundation
import Testing
@testable import ImpKit

/// Runs `Tests/Fixtures/link-messages.json` and `bridge-messages.json`, which other clients read too.
@Suite struct ProtocolVectorTests {
    static func load(_ name: String) -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
    }

    static func data(_ json: Any) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed]) }

    /// Parsed values compare equal whatever the key order or number spelling.
    static func same(_ a: Data, _ b: Data) throws -> Bool {
        let x = try JSONSerialization.jsonObject(with: a), y = try JSONSerialization.jsonObject(with: b)
        return (x as AnyObject).isEqual(y)
    }

    static func list(_ doc: [String: Any], _ key: String) throws -> [[String: Any]] {
        let items = try #require(doc[key] as? [[String: Any]])
        #expect(!items.isEmpty)
        return items
    }

    // MARK: Device link

    @Test func everyLinkMessageCaseHasAVector() throws {
        let names = Set(try Self.list(Self.load("link-messages.json"), "valid").compactMap { ($0["json"] as? [String: Any])?.keys.first })
        let cases: Set<String> = ["hello", "welcome", "ping", "pong", "bye", "routes", "stage", "pass", "took", "declined",
                                  "claim", "claimed", "gone", "release", "ask", "stop", "newChat", "felt", "file", "talks",
                                  "look", "chat", "work", "mood", "animate", "speech", "filePart", "fileFailed", "talkLines",
                                  "message", "answer", "adopt", "adopted"]
        #expect(names == cases)
    }

    @Test func linkVectorsDecodeAndEncodeAgain() throws {
        for v in try Self.list(Self.load("link-messages.json"), "valid") {
            let name = v["name"] as! String
            let body = try Self.data(v["json"]!)
            let message = try #require(LinkFrame.decode(LinkMessage.self, body), "\(name)")
            #expect(message.isSound, "\(name)")
            let again = try JSONEncoder.link.encode(message)
            #expect(try Self.same(again, try Self.data(v["reencodes"] ?? v["json"]!)), "\(name)")
            // And through a frame, as it travels.
            var frames = LinkFrame()
            let got = try frames.feed(try LinkFrame.encode(message))
            #expect(got.count == 1)
            #expect(LinkFrame.decode(LinkMessage.self, got[0]) == message, "\(name)")
        }
    }

    @Test func linkMessagesThatMustBeRejectedAreRejected() throws {
        let doc = Self.load("link-messages.json")
        for key in ["unknown", "malformed"] {
            for v in try Self.list(doc, key) {
                #expect(LinkFrame.decode(LinkMessage.self, try Self.data(v["json"]!)) == nil, "\(v["name"]!)")
            }
        }
        for v in try Self.list(doc, "unsound") {
            let message = try #require(LinkFrame.decode(LinkMessage.self, try Self.data(v["json"]!)), "\(v["name"]!)")
            #expect(!message.isSound, "\(v["name"]!)")
        }
        #expect(doc["version"] as? Int == LinkProtocol.version)
    }

    // MARK: Browser bridge

    @Test func bridgeOutboundVectorsAreWhatTheAppSends() throws {
        for v in try Self.list(Self.load("bridge-messages.json"), "outbound") {
            let json = v["json"] as! [String: Any]
            let message: BridgeOutbound
            switch json["type"] as! String {
            case "locate": message = .locate(id: json["id"] as! String, query: json["query"] as! String)
            case "text": message = .text(id: json["id"] as! String, limit: json["limit"] as! Int)
            case "troupe":
                let imps = try JSONDecoder().decode([BridgeImp].self, from: try Self.data(json["imps"]!))
                message = .troupe(imps)
            default: Issue.record("unknown outbound type in \(v["name"]!)"); continue
            }
            #expect(try Self.same(message.encoded(), try Self.data(json)), "\(v["name"]!)")
        }
    }

    @Test func bridgeInboundVectorsDecodeToWhatTheyExpect() throws {
        for v in try Self.list(Self.load("bridge-messages.json"), "inbound") {
            let message = try #require(BridgeInbound.decode(try Self.data(v["json"]!)), "\(v["name"]!)")
            let expect = v["expect"] as! [String: Any]
            switch message {
            case .hello(let browser, let version):
                #expect(expect["type"] as? String == "hello" && expect["browser"] as? String == browser && expect["version"] as? Int == version)
            case .page(let url, let title):
                #expect(expect["type"] as? String == "page" && expect["url"] as? String == url && expect["title"] as? String == title)
            case .located(let id, let rect):
                #expect(expect["type"] as? String == "located" && expect["id"] as? String == id)
                if let r = expect["rect"] as? [String: Double] {
                    #expect(rect == BridgeRect(x: r["x"]!, y: r["y"]!, width: r["width"]!, height: r["height"]!))
                } else {
                    #expect(rect == nil)
                }
            case .text(let id, let text):
                #expect(expect["type"] as? String == "text" && expect["id"] as? String == id && expect["text"] as? String == text)
            case .pong:
                #expect(expect["type"] as? String == "pong")
            }
        }
    }

    @Test func invalidBridgeMessagesAreRejected() throws {
        for v in try Self.list(Self.load("bridge-messages.json"), "invalid") {
            #expect(BridgeInbound.decode(try Self.data(v["json"]!)) == nil, "\(v["name"]!)")
        }
    }
}
