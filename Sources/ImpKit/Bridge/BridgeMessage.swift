import Foundation
import CoreGraphics

/// A page in the browser's active tab.
public struct BrowserPage: Equatable, Sendable, Codable {
    public var url: String
    public var title: String
    public var browser: String
    public init(url: String, title: String, browser: String) {
        self.url = url; self.title = title; self.browser = browser
    }
}

/// A rectangle as the browser reports it: screen points, origin top-left of the primary display.
public struct BridgeRect: Equatable, Sendable, Codable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// An Imp as the extension's popup draws it: only its looks and what it's up to, nothing it said.
public struct BridgeImp: Equatable, Sendable, Codable {
    public var name: String
    /// Skin colour as a hue (0…1, red is 0).
    public var hue: Double
    public var scale: Double
    /// A `Mood` raw value ("idle", "thinking", "working", "sleepy"…).
    public var mood: String
    /// Out on an iPhone, not on this Mac's desktop.
    public var away: Bool

    public init(name: String, hue: Double, scale: Double, mood: String, away: Bool) {
        self.name = name; self.hue = hue; self.scale = scale; self.mood = mood; self.away = away
    }
}

/// Extension → app.
public enum BridgeInbound: Equatable, Sendable, Decodable {
    case hello(browser: String, version: Int)
    case page(url: String, title: String)
    case located(id: String, rect: BridgeRect?)
    case text(id: String, text: String)
    case pong

    private enum Key: String, CodingKey { case type, browser, version, url, title, id, rect, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(browser: try c.decodeIfPresent(String.self, forKey: .browser) ?? "Browser",
                          version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        case "page":
            self = .page(url: try c.decode(String.self, forKey: .url),
                         title: try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        case "located":
            self = .located(id: try c.decode(String.self, forKey: .id),
                            rect: try c.decodeIfPresent(BridgeRect.self, forKey: .rect))
        case "text":
            self = .text(id: try c.decode(String.self, forKey: .id),
                         text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "pong": self = .pong
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public static func decode(_ data: Data) -> BridgeInbound? {
        try? JSONDecoder().decode(BridgeInbound.self, from: data)
    }
}

/// App → extension.
public enum BridgeOutbound: Equatable, Sendable, Encodable {
    case locate(id: String, query: String)
    case text(id: String, limit: Int)
    /// The Imps out right now, for the extension's popup to draw (sent on connect and when they
    /// change). An extension that doesn't know it ignores it.
    case troupe([BridgeImp])

    private enum Key: String, CodingKey { case type, id, query, limit, imps }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .locate(let id, let query):
            try c.encode("locate", forKey: .type); try c.encode(id, forKey: .id); try c.encode(query, forKey: .query)
        case .text(let id, let limit):
            try c.encode("text", forKey: .type); try c.encode(id, forKey: .id); try c.encode(limit, forKey: .limit)
        case .troupe(let imps):
            try c.encode("troupe", forKey: .type); try c.encode(imps, forKey: .imps)
        }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

public enum Bridge {
    /// Only browser extensions may talk to the bridge: web pages can't forge the `Origin` header.
    public static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return false }
        return ["chrome-extension://", "moz-extension://", "safari-web-extension://"].contains { origin.hasPrefix($0) }
    }

    /// Top-left-origin screen points (browser) to Cocoa's bottom-left origin.
    public static func cocoaRect(_ r: BridgeRect, primaryScreenHeight: Double) -> CGRect {
        CGRect(x: r.x, y: primaryScreenHeight - r.y - r.height, width: r.width, height: r.height)
    }
}
