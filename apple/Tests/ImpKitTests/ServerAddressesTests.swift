import Foundation
import Testing
@testable import ImpKit

/// The Den and the Hop are two settings. The core does the checking (its vectors are in
/// `spec/fixtures/server-addresses.json`), so these tests cover the Swift side: that each setting
/// stands alone, that each feature reads only its own, and what an empty or half-set pair does.
@Suite struct ServerAddressesTests {
    @Test func theCoreChecksTheAddresses() {
        #expect(DenServer("den.example.com")?.url.absoluteString == "https://den.example.com")
        #expect(DenServer("http://localhost:8080")?.url.absoluteString == "http://localhost:8080")
        #expect(DenServer("") == nil)
        #expect(DenServer("https://den.example.com/path") == nil)
        #expect(DenServer("ftp://den.example.com") == nil)
        #expect(HopServer("hop.example.com")?.address == "hop.example.com:4677")
        #expect(HopServer("hop.example.com:9000")?.port == 9000)
        #expect(HopServer("https://hop.example.com") == nil)
        #expect(HopServer("hop.example.com:0") == nil)
        #expect(HopServer("") == nil)
    }

    @Test func wrongAddressesGetASentence() {
        #expect(ServerKind.den.problem(with: "ftp://x.example.com") == "The Den address must start with http:// or https://.")
        #expect(ServerKind.hop.problem(with: "hop.example.com:99999") == "The port must be a number from 1 to 65535.")
        #expect(ServerKind.den.problem(with: "") == nil, "empty means off, not wrong")
        #expect(ServerKind.hop.problem(with: "") == nil)
    }

    @Test func theChoicesFillInAndRecogniseAddresses() {
        for kind in [ServerKind.den, .hop] {
            #expect(ServerChoice.of("", kind) == .off)
            #expect(ServerChoice.of(kind.defaultAddress, kind) == .imps)
            #expect(ServerChoice.of(kind.localAddress, kind) == .custom, "a server run here is a custom one")
            #expect(ServerChoice.of("other.example.com", kind) == .custom)
            #expect(ServerChoice.imps.address(kind) == kind.defaultAddress)
            #expect(ServerChoice.off.address(kind) == "")
            #expect(ServerChoice.custom.address(kind) == nil)
        }
        #expect(DenServer(ServerKind.den.defaultAddress) != nil && DenServer(ServerKind.den.localAddress) != nil)
        #expect(HopServer(ServerKind.hop.defaultAddress) != nil && HopServer(ServerKind.hop.localAddress) != nil)
        #expect(ServerKind.isOnThisDevice(ServerKind.hop.localAddress) && ServerKind.isOnThisDevice(ServerKind.den.localAddress))
        #expect(ServerKind.isOnThisDevice("127.0.0.1:4677") && ServerKind.isOnThisDevice("http://LOCALHOST:8080/"))
        #expect(!ServerKind.isOnThisDevice(ServerKind.hop.defaultAddress) && !ServerKind.isOnThisDevice("localhostess.com"))
    }

    @Test func eachSetupIsItsOwn() {
        #expect(ServerSetup(den: "", hop: "").den == nil && ServerSetup(den: "", hop: "").hop == nil)
        let onlyDen = ServerSetup(den: "den.example.com", hop: "")
        #expect(onlyDen.den != nil && onlyDen.hop == nil)
        let onlyHop = ServerSetup(den: "", hop: "hop.example.com")
        #expect(onlyHop.den == nil && onlyHop.hop != nil)
        let wrongHop = ServerSetup(den: "den.example.com", hop: "https://hop.example.com")
        #expect(wrongHop.den != nil && wrongHop.hop == nil, "a wrong Hop does not touch the Den")
    }

    // MARK: The Mac's preferences

    @Test func theMacKeepsTwoSettings() throws {
        var prefs = ImpPreferences()
        #expect(prefs.den == ServerKind.den.defaultAddress && prefs.hop == ServerKind.hop.defaultAddress)
        prefs.den = ""
        #expect(prefs.hop == ServerKind.hop.defaultAddress, "turning the Den off leaves the Hop")
        prefs.hop = "hop.example.com:9000"
        #expect(prefs.den == "")
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.den == "" && back.hop == "hop.example.com:9000")
    }

    @Test func theOldSingleServerIsNotRead() throws {
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpPreferences())) as? [String: Any])
        saved["serverAddress"] = "old.example.com"
        let json = try JSONSerialization.data(withJSONObject: saved)
        let prefs = try JSONDecoder().decode(ImpPreferences.self, from: json)
        #expect(prefs.den == ServerKind.den.defaultAddress && prefs.hop == ServerKind.hop.defaultAddress)
    }

    // MARK: The iPhone's storage

    @Test func theIPhoneKeepsTwoKeys() throws {
        let suite = "ServerStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old.example.com", forKey: "serverAddress")
        let store = ServerStore(defaults)
        #expect(store.den == ServerKind.den.defaultAddress && store.hop == ServerKind.hop.defaultAddress, "the old key is ignored")
        store.hop = ""
        #expect(defaults.string(forKey: ServerStore.hopKey) == "" && defaults.string(forKey: ServerStore.denKey) == nil)
        store.den = "den.example.com"
        #expect(store.den == "den.example.com" && store.hop == "")
        #expect(ServerStore.denKey != ServerStore.hopKey)
    }

    // MARK: Each feature reads only its own

    @Test func theDenClientUsesOnlyTheDenAddress() throws {
        var prefs = ImpPreferences()
        prefs.den = "den.example.com"
        prefs.hop = "hop.example.com:9000"
        let client = DenClient(server: try #require(DenServer(prefs.den)))
        #expect(client.page(of: try #require(DenItemID(handle: "pip", slug: "wave"))).host == "den.example.com")
        prefs.hop = ""
        #expect(DenServer(prefs.den) != nil, "no Hop does not stop the Den")
        prefs.den = ""
        #expect(DenServer(prefs.den) == nil, "no Den means no client, even with a Hop")
    }

    @Test func theLinkUsesOnlyTheHopAddress() {
        var prefs = ImpPreferences()
        prefs.den = "den.example.com"
        prefs.hop = "hop.example.com:9000"
        #expect(HopServer(prefs.hop)?.address == "hop.example.com:9000")
        prefs.den = ""
        #expect(HopServer(prefs.hop)?.address == "hop.example.com:9000", "no Den does not stop the link")
        prefs.hop = ""
        prefs.den = "den.example.com"
        #expect(HopServer(prefs.hop) == nil, "a Den is not a Hop")
    }
}
