import Foundation
import Testing
@testable import ImpKit

@Suite struct ServicePresetTests {
    @Test func theChoicesAreRemoteAndLocalFromTheDataFile() {
        #expect(ServicePreset.all.map(\.id) == ["remote", "local"])
        #expect(ServicePreset.all.map(\.isLocal) == [false, true])
        #expect(ServicePreset.standard?.id == "remote")
        #expect(ServicePreset.remote?.baseURL == "https://openrouter.ai/api/v1")
        #expect(ServicePreset.local?.baseURL == "http://localhost:11434/v1")
        #expect(ServicePreset.all.allSatisfy { $0.link.scheme == "https" && !$0.symbol.isEmpty })
    }

    @Test func addressesFindTheirPreset() {
        #expect(ServicePreset.matching("https://openrouter.ai/api/v1/")?.id == "remote")
        #expect(ServicePreset.matching("http://my-mac.local:11434/v1")?.id == "local")
        #expect(ServicePreset.matching("http://192.168.1.4:1234/v1") == nil, "any other local server is an edited address")
        #expect(ServicePreset.matching("https://example.com/v1") == nil)
        #expect(ServicePreset.matching("http://localhost/v1") == nil)
        #expect(ServicePreset.matching("") == nil)
    }

    @Test func aLocalPresetMovesToAnotherHost() {
        let ollama = ServicePreset.all[1]
        #expect(ollama.baseURL(onHost: "my-mac.local") == "http://my-mac.local:11434/v1")
        #expect(ServicePreset.all[0].baseURL(onHost: "my-mac.local") == "https://openrouter.ai/api/v1")
    }

    @Test func addressesAreCheckedBeforeAnyRequest() {
        #expect(ServicePreset.isValidAddress(" https://example.com/v1 "))
        #expect(ServicePreset.isValidAddress("http://192.168.1.4:1234/v1"))
        #expect(!ServicePreset.isValidAddress("example.com/v1"))
        #expect(!ServicePreset.isValidAddress("ftp://example.com"))
        #expect(!ServicePreset.isValidAddress(""))
    }

    @Test func ownComputersAreRecognised() {
        #expect(ServicePreset.isOwnComputer("http://localhost:8080/v1"))
        #expect(ServicePreset.isOwnComputer("http://my-mac.local:1234/v1"))
        #expect(!ServicePreset.isOwnComputer("https://openrouter.ai/api/v1"))
    }
}
