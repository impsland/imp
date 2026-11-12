import ImpCore
import Foundation

// The shapes Imp Link passes around. They hold data only. Every rule (what a valid device, card or route is,
// who may talk to whom, where an Imp goes) lives in `imp-core`, which checks what it hands over.

/// The protocol's limits, from the core.
public enum LinkProtocol {
    public static let serviceType = linkLimits().serviceType
    public static let port = linkLimits().port
    /// Frames bigger than this are refused (chats are sent a page at a time).
    public static let maxFrame = Int(linkLimits().maxFrame)
    public static let maxText = Int(linkLimits().maxText)
}

/// What kind of device this is.
public enum LinkKind: String, Codable, Sendable, Equatable {
    case mac, phone
}

/// Who a device says it is, as other devices know it. Public things only.
public struct LinkDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: LinkKind
    /// The public key other devices pin.
    public var key: Data
    /// The key that names the device's room at the Hop.
    public var room: Data

    public init(id: UUID, name: String, kind: LinkKind, key: Data, room: Data = Data(count: 32)) {
        self.id = id; self.name = name; self.kind = kind; self.key = key; self.room = room
    }
}

/// Where a device can be reached: host names, a port, and the Hop it waits at (`host:port`).
public struct LinkRoutes: Codable, Sendable, Equatable {
    public var hosts: [String]
    public var port: UInt16
    public var hop: String?

    public init(hosts: [String], port: UInt16 = LinkProtocol.port, hop: String? = nil) {
        self.hosts = hosts; self.port = port; self.hop = hop
    }
}

/// A device's visiting card: who it is, the key that opens its door, and where to reach it.
public struct LinkCard: Codable, Sendable, Equatable {
    public var device: LinkDevice
    public var door: Data
    public var routes: LinkRoutes

    public var id: UUID { device.id }
}

/// A device this one has a link with.
public struct LinkRecord: Codable, Sendable, Equatable, Identifiable {
    public var device: LinkDevice
    public var door: Data?
    public var routes: LinkRoutes
    public var since: Date
    public var trusted: Bool

    public var id: UUID { device.id }
    public var card: LinkCard? { door.map { LinkCard(device: device, door: $0, routes: routes) } }
}

/// How much a connected device is trusted.
public enum LinkStanding: String, Codable, Sendable, Equatable {
    case peer, visitor
}

/// How an Imp's body got to the screen it is on.
public enum LinkTravel: Codable, Sendable, Equatable {
    case home
    case visit(side: LinkSide, from: UUID)
}

/// Where a thrown Imp goes. The core decides.
public enum LinkDoors {
    public enum Bounce: Sendable, Equatable {
        case nobodyConnected
        case wayBackIsClosed
        case nowhereElse
    }

    public enum Outcome: Sendable, Equatable {
        case to(UUID)
        case bounce(Bounce)
    }

    /// One device's share of a side: the heights from `top` to `bottom` (0 is the top).
    public struct Band: Sendable, Equatable {
        public var device: UUID
        public var top: Double
        public var bottom: Double
    }
}

/// The Imps visiting this device: for each one, how it came in and its home's card.
public struct Visits: Codable, Sendable, Equatable {
    public struct Visit: Codable, Sendable, Equatable, Identifiable {
        public var imp: LinkImp
        public var home: LinkCard
        public var ticket: Data
        public var side: LinkSide
        public var from: UUID

        public var id: UUID { imp.id }
    }

    public var visits: [Visit] = []

    public init(_ visits: [Visit] = []) { self.visits = visits }

    public func visit(of imp: UUID) -> Visit? { visits.first { $0.imp.id == imp } }
}

/// The Imps of this device that are away, and who holds each.
public struct AwayLedger: Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var imp: UUID
        public var holder: UUID
    }

    public var entries: [Entry] = []

    public func holder(of imp: UUID) -> UUID? { entries.first { $0.imp == imp }?.holder }
}

extension JSONEncoder {
    static var link: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    static var link: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// A Hop address as the core writes it: `host:port`.
public struct HopAddress: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init?(_ text: String) {
        guard let normal = linkHopAddress(text: text), let colon = normal.lastIndex(of: ":"),
              let port = UInt16(normal[normal.index(after: colon)...]) else { return nil }
        host = String(normal[..<colon])
        self.port = port
    }

    public var text: String { "\(host):\(port)" }
}

/// A code a person scans or pastes. The core reads and writes it.
public struct LinkInvite: Equatable, Sendable {
    public let url: URL
    public let device: LinkDevice

    public init?(string: String) {
        guard let info = linkParseInvite(text: string), let made = Self.make(info) else { return nil }
        self = made
    }

    /// An invite made of its parts (previews and tests).
    public init?(device: LinkDevice, door: Data, invite: Data, routes: LinkRoutes) {
        guard let device = try? String(decoding: JSONEncoder.link.encode(device), as: UTF8.self),
              let routes = try? String(decoding: JSONEncoder.link.encode(routes), as: UTF8.self),
              let info = try? linkMakeInvite(device: device, door: door, invite: invite, routes: routes),
              let made = Self.make(info) else { return nil }
        self = made
    }

    init?(info: LinkInviteInfo) {
        guard let made = Self.make(info) else { return nil }
        self = made
    }

    private static func make(_ info: LinkInviteInfo) -> LinkInvite? {
        guard let url = URL(string: info.url), let device = try? JSONDecoder.link.decode(LinkDevice.self, from: Data(info.device.utf8)) else { return nil }
        return LinkInvite(url: url, device: device)
    }

    private init(url: URL, device: LinkDevice) { self.url = url; self.device = device }
}

public protocol LinkStorage: Sendable {
    func load() throws -> Data?
    func save(_ book: Data) throws
}

/// The book in a file only this user can read.
public struct LinkFileStorage: LinkStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Written beside the book with its final permissions, then moved over it: no moment where
        // another user could read it, and no half-written book if we die midway.
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        do {
            try data.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count, let base = raw.baseAddress {
                    let n = write(fd, base + done, raw.count - done)
                    guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
                    done += n
                }
            }
            guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temp.path)
            #endif
            guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}

public final class LinkMemoryStorage: LinkStorage, @unchecked Sendable {   // `book` is only touched under `lock`
    private let lock = NSLock()
    private var book: Data?

    public init(_ book: Data? = nil) { self.book = book }

    public func load() throws -> Data? { lock.withLock { book } }
    public func save(_ book: Data) throws { lock.withLock { self.book = book } }
}
