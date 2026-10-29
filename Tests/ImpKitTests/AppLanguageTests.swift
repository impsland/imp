import Foundation
import Testing
@testable import ImpKit

@Suite struct AppLanguageTests {
    @Test func readsWhatWasChosenForImpAlone() {
        #expect(AppLanguage.chosen(in: nil) == nil)
        #expect(AppLanguage.chosen(in: [:]) == nil)
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["es"]]) == "es")
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["es-MX"]]) == "es")
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["zh-Hans-CN"]]) == "zh-Hans")
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["en-GB", "es"]]) == "en")
        // Not translated: shown as following the Mac.
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["de"]]) == nil)
        #expect(AppLanguage.chosen(in: ["AppleLanguages": ["zh-Hant"]]) == nil)
    }

    @Test func choosingWritesWhatSystemSettingsWrites() throws {
        let suite = "imp-language-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguage.choose("zh-Hans", in: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["zh-Hans"])
        #expect(AppLanguage.chosen(in: defaults.persistentDomain(forName: suite)) == "zh-Hans")
        AppLanguage.choose(nil, in: defaults)
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        AppLanguage.choose("fr", in: defaults)               // not one of Imp's: follows the Mac
        #expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
    }

    @Test func resolvesWhatImpWillShow() {
        #expect(AppLanguage.resolved(chosen: "es", system: ["en-US"]) == "es")
        #expect(AppLanguage.resolved(chosen: nil, system: ["zh-Hans-CN", "en"]) == "zh-Hans")
        #expect(AppLanguage.resolved(chosen: nil, system: ["de-DE", "es-ES"]) == "es")
        #expect(AppLanguage.resolved(chosen: nil, system: ["de-DE"]) == "en")
    }

    @Test func namesEachLanguageInItself() {
        #expect(AppLanguage.name("en") == "English")
        #expect(AppLanguage.name("es") == "Español")
        #expect(AppLanguage.name("zh-Hans").hasPrefix("中文") || AppLanguage.name("zh-Hans").contains("简体"))
    }
}
