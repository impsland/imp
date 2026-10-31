import Foundation

/// A device this one has a link with: who it is (its key is pinned) and how to dial it.
public struct LinkRecord: Codable, Sendable, Equatable, Identifiable {
    public var device: LinkDevice
    /// Its door key, which opens its TLS. Unknown until it tells us (a device that scanned our code).
    public var door: Data?
    public var routes: LinkRoutes
    public var since: Date

    public var id: UUID { device.id }

    public init(device: LinkDevice, door: Data?, routes: LinkRoutes, since: Date = Date()) {
        self.device = device; self.door = door; self.routes = routes; self.since = since
    }

    /// What it takes to dial this device, if we know its door key.
    var card: LinkCard? { door.map { LinkCard(device: device, door: $0, routes: routes) } }
}

/// Everything a device remembers about its links: its identity key, its door key, the invite on
/// show, its links, the Imps visiting it and the Imps of its own that are away. It holds secrets, so
/// it is only ever written through `LinkStorage`, and never logged.
public struct LinkBook: Codable, Sendable, Equatable, CustomStringConvertible {
    public var version = 1
    public var device: UUID
    /// The identity key's raw bytes.
    public var seed: Data
    /// Opens this device's TLS. New when it forgets everyone.
    public var door: Data
    /// The invite key on show, and when the code was last on screen.
    public var invite: Data?
    public var inviteShown: Date?
    public var links: [LinkRecord] = []
    public var visits = Visits()
    public var away = AwayLedger()

    public init(device: UUID, seed: Data, door: Data) {
        self.device = device; self.seed = seed; self.door = door
    }

    public var description: String { "LinkBook(\(links.count) links, \(visits.visits.count) visits, \(away.entries.count) away)" }
}

/// Where the book lives.
public protocol LinkStorage: Sendable {
    /// The saved book, nil if there is none yet. Throws when there is one that can't be read.
    func load() throws -> LinkBook?
    func save(_ book: LinkBook) throws
}

/// The book in a file: replaced atomically, readable by this user only, and on iOS readable once the
/// phone has been unlocked after a restart (so a link can come back in the background).
public struct LinkFileStorage: LinkStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> LinkBook? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.link.decode(LinkBook.self, from: Data(contentsOf: url))
    }

    public func save(_ book: LinkBook) throws {
        let data = try JSONEncoder.link.encode(book)
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
                while done < raw.count {
                    let n = write(fd, raw.baseAddress! + done, raw.count - done)
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

/// A book kept in memory, for tests.
public final class LinkMemoryStorage: LinkStorage, @unchecked Sendable {   // `book` is only touched under `lock`
    private let lock = NSLock()
    private var book: LinkBook?

    public init(_ book: LinkBook? = nil) { self.book = book }

    public func load() throws -> LinkBook? { lock.withLock { book } }
    public func save(_ book: LinkBook) throws { lock.withLock { self.book = book } }
}
