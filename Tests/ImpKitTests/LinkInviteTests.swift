import CryptoKit
import Foundation
import Testing
@testable import ImpKit

/// Devices with fixed keys, so ids and orders in the tests are the same on every run.
func linkDevice(_ n: Int, name: String? = nil, kind: LinkKind = .mac) -> LinkIdentity {
    let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    return LinkIdentity(id: id, name: name ?? "Device \(n)", kind: kind, seed: Data(repeating: UInt8(n), count: 32))!
}

func linkCard(_ identity: LinkIdentity, routes: LinkRoutes = .none) -> LinkCard {
    LinkCard(device: identity.device, door: Data(identity.publicKey.reversed()), routes: routes)
}

@Suite struct LinkInviteTests {
    let host = linkDevice(1, name: "Art’s MacBook Pro")
    let door = Data((0..<32).map { UInt8($0) })
    let secret = Data((0..<32).map { UInt8(100 + $0) })

    func invite(hosts: [String] = ["art.local", "192.168.1.7"], port: UInt16 = LinkProtocol.port, hop: String? = "imp.example.org:4677") -> LinkInvite {
        LinkInvite(device: host.device, door: door, invite: secret, routes: LinkRoutes(checking: hosts, port: port, hop: hop)!)
    }

    /// The code with one query item replaced, dropped (nil) or added.
    func tweak(_ name: String, _ value: String?, of invite: LinkInvite? = nil) -> URL {
        var c = URLComponents(url: (invite ?? self.invite()).url, resolvingAgainstBaseURL: false)!
        c.queryItems = c.queryItems!.filter { $0.name != name } + (value.map { [URLQueryItem(name: name, value: $0)] } ?? [])
        return c.url!
    }

    @Test func roundTrips() throws {
        let i = invite()
        #expect(i.url.scheme == "implink" && i.url.host == "join")
        #expect(LinkInvite(url: i.url) == i)
        #expect(LinkInvite(string: "  \(i.url.absoluteString)\n") == i)
        // The port is only written when it isn't the usual one.
        #expect(!i.url.absoluteString.contains("&p="))
        let odd = invite(port: 50_001)
        #expect(LinkInvite(url: odd.url)?.routes.port == 50_001)
        // No hosts, no hop: just the keys.
        let bare = invite(hosts: [], hop: nil)
        #expect(LinkInvite(url: bare.url) == bare)
        #expect(!bare.url.absoluteString.contains("h=") && !bare.url.absoluteString.contains("hop="))
    }

    @Test func theCodeHoldsTheSpecifiedFields() throws {
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: invite().url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["v"] == "2" && items["d"] == host.id.uuidString && items["t"] == "mac")
        #expect(items["k"] == LinkInvite.base64URL(host.publicKey) && items["door"] == LinkInvite.base64URL(door) && items["inv"] == LinkInvite.base64URL(secret))
        #expect(items["h"] == "art.local,192.168.1.7" && items["hop"] == "imp.example.org:4677")
        #expect(!(items["k"] ?? "").contains("=") && !(items["door"] ?? "").contains("+"))
    }

    @Test func namesSurviveAnyCharacters() {
        for name in ["Art’s Mac & friends", "a=b+c%20d", "日本語 🧡", "x?y#z/w"] {
            var i = invite()
            i.device = LinkDevice(id: host.id, name: name, kind: .mac, key: host.publicKey)
            #expect(LinkInvite(url: i.url)?.device.name == name, "\(name)")
        }
        // Names are cleaned like everywhere: trimmed, capped, never empty.
        #expect(LinkDevice.cleaned("   ", kind: .phone) == "iPhone" && LinkDevice.cleaned("\n", kind: .mac) == "Mac")
        #expect(LinkDevice.cleaned(String(repeating: "n", count: 500), kind: .mac).count == LinkDevice.longestName)
        #expect(LinkInvite(url: tweak("n", ""))?.device.name == "Mac")
        #expect(LinkInvite(url: tweak("n", nil))?.device.name == "Mac")
    }

    @Test func rejectsWhatIsNotWhole() {
        #expect(LinkInvite(url: tweak("v", "2")) != nil)
        for (name, value) in [("v", "1"), ("v", "3"), ("v", "02"), ("v", nil),
                              ("d", "nope"), ("d", nil), ("t", "tablet"), ("t", nil),
                              ("k", "c2hvcnQ"), ("k", nil), ("door", nil), ("inv", nil),
                              ("door", LinkInvite.base64URL(Data(repeating: 1, count: 31))),
                              ("inv", LinkInvite.base64URL(Data(repeating: 1, count: 33))),
                              ("k", LinkInvite.base64URL(Data(repeating: 1, count: 32)) + "="),
                              ("door", String(repeating: "+", count: 43)),
                              ("inv", String(repeating: "/", count: 43)),
                              ("inv", " " + LinkInvite.base64URL(secret)),
                              ("h", "a b"), ("h", "A.local,"), ("h", ",a.local"), ("h", "x/y"), ("h", "a..b"), ("h", "-a.local"),
                              ("h", (0..<9).map { "h\($0).local" }.joined(separator: ",")),
                              ("p", "0"), ("p", "65536"), ("p", "+80"), ("p", "-1"), ("p", "８０"), ("p", "80a"), ("p", ""),
                              ("hop", "host"), ("hop", "host:0"), ("hop", "a b:80"), ("hop", "host:99999")] as [(String, String?)] {
            #expect(LinkInvite(url: tweak(name, value)) == nil, "\(name)=\(value ?? "nil")")
        }
    }

    @Test func aStrictBase64OnlyHasOneSpelling() {
        // The last character of a 32-byte key only has 4 meaningful bits: another spelling of the same key is no key.
        let good = LinkInvite.base64URL(secret)
        let last = good.last!
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let sibling = alphabet.first { $0 != last && LinkInvite.data(base64URL: String(good.dropLast()) + String($0)) == secret }
        #expect(sibling == nil)
        #expect(LinkInvite.data(base64URL: good) == secret)
        #expect(LinkInvite.data(base64URL: "") == Data())
        #expect(LinkInvite.data(base64URL: "a") == nil)
    }

    @Test func rejectsBrokenAddressesAndOversizedLinks() {
        let mac = UUID().uuidString
        #expect(LinkInvite(string: "implink://join?v=2&d=\(mac)") == nil)
        #expect(LinkInvite(string: "https://join?v=2") == nil)
        #expect(LinkInvite(string: "implink://pair?v=2") == nil)
        #expect(LinkInvite(string: "") == nil && LinkInvite(string: "not a url") == nil)
        // A repeated name is ambiguous.
        let doubled = invite().url.absoluteString + "&inv=" + LinkInvite.base64URL(Data(repeating: 5, count: 32))
        #expect(LinkInvite(string: doubled) == nil)
        // Far too long, even if it starts like a code.
        let huge = invite().url.absoluteString + "&x=" + String(repeating: "a", count: 3_000)
        #expect(LinkInvite(string: huge) == nil)
        // A valueless item is no value.
        #expect(LinkInvite(string: invite().url.absoluteString + "&flag") == nil)
        // Unknown names are fine: a newer version may add some.
        #expect(LinkInvite(string: invite().url.absoluteString + "&future=1") == invite())
    }

    @Test func descriptionsKeepSecretsOut() {
        let i = invite()
        let text = "\(i) \(String(reflecting: i)) \(i.card.device.id)"
        #expect(!text.contains(LinkInvite.base64URL(door)) && !text.contains(LinkInvite.base64URL(secret)))
        let book = LinkBook(device: host.id, seed: Data(repeating: 9, count: 32), door: door)
        #expect(!"\(book)".contains(LinkInvite.base64URL(door)) && !"\(book)".contains(door.base64EncodedString()))
        #expect(!"\(host)".contains(LinkInvite.base64URL(host.publicKey)))
    }

    @Test func routesAreCheckedAndTidied() {
        #expect(LinkRoutes(checking: ["A.Local", "a.local", " B.local "], port: 1, hop: nil)?.hosts == ["a.local", "b.local"])
        #expect(LinkRoutes(checking: [], port: 0, hop: nil) == nil)
        #expect(LinkRoutes(checking: ["bad host"], port: 1, hop: nil) == nil)
        // Routes a device builds itself keep what's good.
        let own = LinkRoutes(hosts: ["ok.local", "not ok", "OK.local", "10.0.0.2"], port: 0, hop: "nope")
        #expect(own.hosts == ["ok.local", "10.0.0.2"] && own.port == LinkProtocol.port && own.hop == nil)
        #expect(LinkRoutes(hosts: (0..<20).map { "h\($0).local" }).hosts.count == LinkRoutes.mostHosts)
    }
}

@Suite struct LinkCryptoTests {
    let door = Data(32..<64)

    @Test func keysAreDerivedNeverTheDoorItself() {
        #expect(LinkCrypto.psk(door: door) == LinkCrypto.psk(door: door))
        #expect(LinkCrypto.psk(door: door).count == 32 && LinkCrypto.psk(door: door) != door)
        #expect(LinkCrypto.psk(door: door) != LinkCrypto.gate(door: door))
        #expect(LinkCrypto.psk(door: Data(repeating: 0, count: 32)) != LinkCrypto.psk(door: door))
        #expect(LinkCrypto.pskIdentity == Data("imp-link/2".utf8))
        #expect(LinkCrypto.randomKey().count == 32 && LinkCrypto.randomKey() != LinkCrypto.randomKey())
    }

    @Test func proofsTieToTheirConnection() {
        let binding = Data(repeating: 1, count: 32), other = Data(repeating: 2, count: 32)
        let a = linkDevice(1), b = linkDevice(2)
        let hello = LinkCrypto.helloMessage(binding: binding, host: b.id)
        #expect(hello == Data("imp-link/2 hello".utf8) + binding + Data(withUnsafeBytes(of: b.id.uuid) { Data($0) }) && hello.count == 16 + 32 + 16)
        let proof = a.sign(hello)
        #expect(LinkIdentity.verify(proof, of: hello, key: a.publicKey))
        // Another connection, another host, another key, a welcome: none will do.
        #expect(!LinkIdentity.verify(proof, of: LinkCrypto.helloMessage(binding: other, host: b.id), key: a.publicKey))
        #expect(!LinkIdentity.verify(proof, of: LinkCrypto.helloMessage(binding: binding, host: a.id), key: a.publicKey))
        #expect(!LinkIdentity.verify(proof, of: hello, key: b.publicKey))
        #expect(!LinkIdentity.verify(proof, of: LinkCrypto.welcomeMessage(binding: binding, guest: b.id), key: a.publicKey))
        #expect(!LinkIdentity.verify(proof.dropLast(), of: hello, key: a.publicKey))
        #expect(!LinkIdentity.verify(proof, of: hello, key: Data(repeating: 0, count: 5)))
    }

    @Test func joinProofsNeedTheInviteAndTheConnection() {
        let invite = LinkCrypto.randomKey(), binding = Data(repeating: 1, count: 32)
        let proof = LinkCrypto.joinProof(invite: invite, binding: binding)
        #expect(LinkCrypto.isValidJoin(proof, invite: invite, binding: binding))
        #expect(!LinkCrypto.isValidJoin(proof, invite: LinkCrypto.randomKey(), binding: binding))
        #expect(!LinkCrypto.isValidJoin(proof, invite: invite, binding: Data(repeating: 2, count: 32)))
        #expect(!LinkCrypto.isValidJoin(Data(), invite: invite, binding: binding))
    }

    @Test func ticketsAreStoredHashedAndCompareInFull() {
        let t = LinkCrypto.mintTicket()
        let h = LinkCrypto.hash(ticket: t)
        #expect(h != t && h.count == 32 && LinkCrypto.matches(ticket: t, hash: h))
        #expect(!LinkCrypto.matches(ticket: LinkCrypto.mintTicket(), hash: h) && !LinkCrypto.matches(ticket: t, hash: t))
        #expect(LinkCrypto.equal(Data([1, 2]), Data([1, 2])) && !LinkCrypto.equal(Data([1, 2]), Data([1, 3])) && !LinkCrypto.equal(Data([1]), Data([1, 2])))
    }

    @Test func identitiesComeBackFromTheirSeed() throws {
        let a = LinkIdentity(name: "  ", kind: .phone)
        #expect(a.name == "iPhone")
        let again = try #require(LinkIdentity(id: a.id, name: "x", kind: .phone, seed: a.seed))
        #expect(again.publicKey == a.publicKey)
        #expect(LinkIdentity(id: a.id, name: "x", kind: .phone, seed: Data([1, 2, 3])) == nil)
        #expect(!"\(a)".contains(a.seed.base64EncodedString()))
    }
}

@Suite struct LinkStorageTests {
    func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("imp-link-\(UUID().uuidString)") }

    @Test func theBookIsPrivateAndRoundTrips() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("link.json")
        let storage = LinkFileStorage(url: url)
        #expect(try storage.load() == nil)
        let a = linkDevice(1), b = linkDevice(2)
        var book = LinkBook(device: a.id, seed: a.seed, door: LinkCrypto.randomKey())
        book.links = [LinkRecord(device: b.device, door: LinkCrypto.randomKey(), routes: LinkRoutes(hosts: ["b.local"]), since: Date(timeIntervalSince1970: 1_700_000_000))]
        book.invite = LinkCrypto.randomKey()
        book.inviteShown = Date(timeIntervalSince1970: 1_700_000_000)
        _ = book.away.mint(UUID(), to: b.id)
        try storage.save(book)
        #expect(try storage.load() == book)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o600 && dirMode == 0o700)
        // Saved again, replaced whole, nothing left beside it.
        book.links = []
        try storage.save(book)
        #expect(try storage.load()?.links.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["link.json"])
    }

    @Test func aBookThatCantBeReadIsAnErrorNotAFreshStart() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("link.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LinkFileStorage(url: url).load() }
    }

    @Test func aBadKeyInTheBookIsRefused() throws {
        let a = linkDevice(1)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.link.encode(LinkBook(device: a.id, seed: a.seed, door: LinkCrypto.randomKey()))) as! [String: Any]
        json["links"] = [["device": ["id": UUID().uuidString, "name": "x", "kind": "mac", "key": Data([1]).base64EncodedString()],
                          "routes": ["hosts": [], "port": 1], "since": 0]]
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder.link.decode(LinkBook.self, from: data) }
    }

    @Test func memoryStorageKeepsTheLastBook() throws {
        let a = linkDevice(1)
        let storage = LinkMemoryStorage()
        #expect(try storage.load() == nil)
        let book = LinkBook(device: a.id, seed: a.seed, door: LinkCrypto.randomKey())
        try storage.save(book)
        #expect(try storage.load() == book)
    }
}
