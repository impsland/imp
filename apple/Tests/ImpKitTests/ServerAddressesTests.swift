import Foundation
import Testing
@testable import ImpKit

/// The Hop is the one server setting. The core does the checking (its vectors are in
/// `spec/fixtures/server-addresses.json`), so these tests cover the Swift side: the choices, the Mac's
/// preference, the iPhone's key and that the link reads only the Hop address.
@Suite struct ServerAddressesTests {
    @Test func theCoreChecksTheAddress() {
        #expect(HopServer("hop.example.com")?.address == "hop.example.com:4677")
        #expect(HopServer("hop.example.com:9000")?.port == 9000)
        #expect(HopServer("https://hop.example.com") == nil)
        #expect(HopServer("hop.example.com:0") == nil)
        #expect(HopServer("") == nil)
    }

    @Test func wrongAddressesGetASentence() {
        #expect(ServerKind.hop.problem(with: "hop.example.com:99999") == "The port must be a number from 1 to 65535.")
        #expect(ServerKind.hop.problem(with: "") == nil, "empty means off, not wrong")
    }

    @Test func theChoicesFillInAndRecogniseAddresses() {
        let kind = ServerKind.hop
        #expect(ServerChoice.of("", kind) == .off)
        #expect(ServerChoice.of(kind.defaultAddress, kind) == .imps)
        #expect(ServerChoice.of(kind.localAddress, kind) == .custom, "a server run here is a custom one")
        #expect(ServerChoice.of("other.example.com", kind) == .custom)
        #expect(ServerChoice.imps.address(kind) == kind.defaultAddress)
        #expect(ServerChoice.off.address(kind) == "")
        #expect(ServerChoice.custom.address(kind) == nil)
        #expect(HopServer(kind.defaultAddress) != nil && HopServer(kind.localAddress) != nil)
        #expect(ServerKind.isOnThisDevice(kind.localAddress))
        #expect(ServerKind.isOnThisDevice("127.0.0.1:4677") && ServerKind.isOnThisDevice("http://LOCALHOST:8080/"))
        #expect(!ServerKind.isOnThisDevice(kind.defaultAddress) && !ServerKind.isOnThisDevice("localhostess.com"))
    }

    @Test func theSetupIsTheHop() {
        #expect(ServerSetup(hop: "").hop == nil)
        #expect(ServerSetup(hop: "hop.example.com").hop != nil)
        #expect(ServerSetup(hop: "https://hop.example.com").hop == nil)
    }

    // MARK: The Mac's preferences

    @Test func theMacKeepsTheHop() throws {
        var prefs = ImpPreferences()
        #expect(prefs.hop == ServerKind.hop.defaultAddress)
        prefs.hop = "hop.example.com:9000"
        let back = try JSONDecoder().decode(ImpPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(back.hop == "hop.example.com:9000")
    }

    @Test func oldSavedAddressesAreIgnored() throws {
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ImpPreferences())) as? [String: Any])
        saved["serverAddress"] = "old.example.com"
        saved["denAddress"] = "den.example.com"
        let json = try JSONSerialization.data(withJSONObject: saved)
        let prefs = try JSONDecoder().decode(ImpPreferences.self, from: json)
        #expect(prefs.hop == ServerKind.hop.defaultAddress)
    }

    // MARK: The iPhone's storage

    @Test func theIPhoneKeepsTheHopKey() throws {
        let suite = "ServerStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old.example.com", forKey: "serverAddress")
        let store = ServerStore(defaults)
        #expect(store.hop == ServerKind.hop.defaultAddress, "the old key is ignored")
        store.hop = ""
        #expect(defaults.string(forKey: ServerStore.hopKey) == "")
        store.hop = "hop.example.com:9000"
        #expect(store.hop == "hop.example.com:9000")
    }
}
