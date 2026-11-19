import Foundation
import Testing
@testable import ImpKit

@Suite struct ListeningLanguagesTests {
    private let supported = ["en-US", "en-GB", "ru-RU", "de-DE", "de-AT", "fr-FR", "es-ES", "es-MX"]

    @Test func theDevicesLanguagesBecomeOneLocaleEach() {
        let ids = ListeningLanguages.candidates(chosen: [], preferred: ["en-GB", "en-US", "ru", "de"], supported: supported,
                                                region: "AT", sticky: nil)
        #expect(ids == ["en-GB", "ru-RU", "de-AT"])
    }

    @Test func picksAreKeptAsTheyAreAndCappedAtThree() {
        let ids = ListeningLanguages.candidates(chosen: ["en-US", "en-GB", "fr-FR", "es-ES"], preferred: ["ru"], supported: supported,
                                                region: nil, sticky: nil)
        #expect(ids == ["en-US", "en-GB", "fr-FR"])
    }

    @Test func theStickyLanguageComesFirst() {
        let ids = ListeningLanguages.candidates(chosen: [], preferred: ["en-US", "ru-RU"], supported: supported, region: nil, sticky: "ru-RU")
        #expect(ids == ["ru-RU", "en-US"])
    }

    @Test func unsupportedLanguagesAreSkipped() {
        let ids = ListeningLanguages.candidates(chosen: [], preferred: ["xx", "es"], supported: supported, region: "MX", sticky: nil)
        #expect(ids == ["es-MX"])
    }

    @Test func theClearlyBetterLanguageWins() {
        let heard = [ListeningLanguages.Heard(locale: "en-US", text: "Pre vet came on", confidence: 0.35, fit: 0.3),
                     ListeningLanguages.Heard(locale: "ru-RU", text: "Привет, как дела", confidence: 0.9, fit: 0.95)]
        #expect(ListeningLanguages.pick(heard, sticky: "en-US")?.locale == "ru-RU")
    }

    @Test func theStickyLanguageWinsACloseCall() {
        let heard = [ListeningLanguages.Heard(locale: "en-US", text: "OK", confidence: 0.7, fit: 0.5),
                     ListeningLanguages.Heard(locale: "de-DE", text: "OK", confidence: 0.72, fit: 0.55)]
        #expect(ListeningLanguages.pick(heard, sticky: "en-US")?.locale == "en-US")
    }

    @Test func withoutConfidenceTheTextDecides() {
        let heard = [ListeningLanguages.Heard(locale: "en-US", text: "hola que tal", confidence: 0, fit: 0.1),
                     ListeningLanguages.Heard(locale: "es-ES", text: "hola qué tal", confidence: 0, fit: 0.9)]
        #expect(ListeningLanguages.pick(heard, sticky: "en-US")?.locale == "es-ES")
    }

    @Test func nothingHeardIsNoAnswer() {
        let heard = [ListeningLanguages.Heard(locale: "en-US", text: " ", confidence: 0, fit: 0)]
        #expect(ListeningLanguages.pick(heard, sticky: nil) == nil)
    }

    @Test func oldSettingsWithoutTheListStillLoad() throws {
        var p = ImpPreferences.withWaitingImp()
        p.dictationLanguages = ["en-US", "ru-RU", "de-DE", "fr-FR"]
        #expect(p.dictationLanguages.count == ListeningLanguages.maxLanguages)
        let data = try JSONEncoder().encode(ImpPreferences.withWaitingImp())
        let back = try JSONDecoder().decode(ImpPreferences.self, from: data)
        #expect(back.dictationLanguages.isEmpty)
    }
}
