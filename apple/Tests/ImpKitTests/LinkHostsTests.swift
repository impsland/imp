import Testing
@testable import ImpKit

/// The addresses a linking code carries, best first, so a phone on the same Wi-Fi finds the Mac.
struct LinkHostsTests {
    @Test func wifiComesBeforeAVPNTunnel() {
        let hosts = LinkNode.orderHosts(localName: "Studio.local", addresses: [
            ("utun6", "10.2.0.2", true),
            ("en0", "192.168.68.53", false),
        ])
        #expect(hosts == ["studio.local", "192.168.68.53", "10.2.0.2"])
    }

    @Test func tunnelsAreKnownByNameAndBridgesGoLastToo() {
        let hosts = LinkNode.orderHosts(localName: "localhost", addresses: [
            ("bridge100", "192.168.64.1", false),
            ("ipsec0", "10.8.0.4", false),
            ("en1", "10.0.0.7", false),
        ])
        #expect(hosts == ["10.0.0.7", "192.168.64.1", "10.8.0.4"])
    }

    @Test func nothingRepeats() {
        let hosts = LinkNode.orderHosts(localName: "", addresses: [
            ("en0", "192.168.1.5", false),
            ("en0", "192.168.1.5", false),
        ])
        #expect(hosts == ["192.168.1.5"])
    }
}
