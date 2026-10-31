import Foundation
import Testing
@testable import ImpKit

@Suite struct ServicePresetTests {
    @Test func presetsAreTheOnesOffered() {
        #expect(ServicePreset.all.map(\.name) == ["OpenRouter", "Ollama", "LM Studio", "OmniRoute"])
        #expect(ServicePreset.all.first { $0.name == "OmniRoute" }?.baseURL == "http://localhost:20128/v1")
        #expect(ServicePreset.all.allSatisfy { $0.link.scheme == "https" })
        #expect(!ServicePreset.all.contains { $0.baseURL.contains("api.openai.com") })
    }

    @Test func addressesFindTheirPreset() {
        #expect(ServicePreset.matching("https://openrouter.ai/api/v1/")?.name == "OpenRouter")
        #expect(ServicePreset.matching("http://my-mac.local:11434/v1")?.name == "Ollama")
        #expect(ServicePreset.matching("http://192.168.1.4:1234/v1")?.name == "LM Studio")
        #expect(ServicePreset.matching("http://localhost:20128/v1")?.name == "OmniRoute")
        #expect(ServicePreset.matching("https://example.com/v1") == nil)
        #expect(ServicePreset.matching("http://localhost/v1") == nil)
        #expect(ServicePreset.matching("") == nil)
    }

    @Test func aLocalPresetMovesToAnotherHost() {
        let ollama = ServicePreset.all[1]
        #expect(ollama.baseURL(onHost: "my-mac.local") == "http://my-mac.local:11434/v1")
        #expect(ServicePreset.all[0].baseURL(onHost: "my-mac.local") == "https://openrouter.ai/api/v1")
    }
}
