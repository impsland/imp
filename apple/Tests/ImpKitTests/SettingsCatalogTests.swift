import Foundation
import Testing
@testable import ImpKit

/// Every setting on a screen is in the catalog, so the Imp can open it for the user.
@Suite struct SettingsCatalogTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Key -> languages that have a text, from the design strings and the string catalog.
    private static let languages: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        let folder = repo.appendingPathComponent("design/strings")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { continue }
            for (key, fields) in json { result[key, default: []].formUnion(["en", "es", "zh-Hans"].filter { fields[$0] != nil }) }
        }
        let catalog = repo.appendingPathComponent("apple/Resources/Localization/Localizable.xcstrings")
        if let data = try? Data(contentsOf: catalog),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = json["strings"] as? [String: [String: Any]] {
            for (key, entry) in strings {
                let have = Set((entry["localizations"] as? [String: Any])?.keys.map { $0 } ?? [])
                // An English literal used as a key is its own English text.
                result[key, default: []].formUnion(have.union(["en"]))
            }
        }
        return result
    }()

    @Test func everySettingHasAPageATitleAndAHint() {
        for setting in SettingID.allCases {
            #expect(SettingsPlace.allCases.contains(setting.page), "\(setting)")
            #expect(!setting.hint.isEmpty, "\(setting)")
            let have = Self.languages[setting.titleKey] ?? []
            #expect(have.isSuperset(of: ["en", "es", "zh-Hans"]), "\(setting.rawValue): \(setting.titleKey) has \(have)")
        }
    }

    @Test func pageTitlesAreTranslated() {
        for page in SettingsPlace.allCases {
            let have = Self.languages[page.titleKey] ?? []
            #expect(have.isSuperset(of: ["en", "es", "zh-Hans"]), "\(page.rawValue): \(page.titleKey)")
        }
    }

    @Test func idsAreUniqueSnakeCaseAndEveryPageHasSettings() {
        let ids = SettingID.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        for id in ids { #expect(id.range(of: #"^[a-z]+(_[a-z]+)+$"#, options: .regularExpression) != nil, "\(id)") }
        for page in SettingsPlace.allCases { #expect(!page.settings.isEmpty, "\(page)") }
        #expect(SettingsPlace.allCases.count == 15)
    }

    @Test func settingsAreOnTheRightKindOfPage() {
        #expect(SettingID.bubbleHideAfter.page == .bubble && !SettingID.bubbleHideAfter.isPerImp)
        #expect(SettingID.lookColour.page == .look && SettingID.lookColour.isPerImp)
        #expect(SettingsPlace.brains.group == .brains && SettingsPlace.brain.group == nil)
        #expect(Set(SettingsPlace.allCases.compactMap(\.group)) == Set(SettingsGroup.allCases))
    }

    @Test func theToolSchemaListsEverySettingAndPage() throws {
        let spec = try #require(OwnTools.specs(Set(ImpToolGroup.allCases), animations: [], imps: [], browser: false)
            .first { $0.name == OwnTools.openSettings })
        let properties = try #require(spec.inputSchema["properties"])
        let settings = try #require(properties["setting"]?["enum"]?.array).compactMap(\.string)
        let pages = try #require(properties["page"]?["enum"]?.array).compactMap(\.string)
        #expect(settings == SettingID.allCases.map(\.rawValue))
        #expect(pages == SettingsPlace.allCases.map(\.rawValue))
        #expect(properties["tool"] != nil && properties["imp"] != nil)
        #expect(spec.description.contains("Any other setting is the user's to change"))
        for page in SettingsPlace.allCases { #expect(spec.description.contains(page.rawValue + ":")) }
    }

    @Test func aRequestMapsToItsPage() {
        let setting = SettingsTarget(setting: "look_colour", page: nil, imp: "Pip")
        #expect(setting == SettingsTarget(page: .look, setting: .lookColour, imp: "Pip"))
        // An app-wide setting ignores the Imp named.
        #expect(SettingsTarget(setting: "bubble_size", page: nil, imp: "Pip") == SettingsTarget(page: .bubble, setting: .bubbleSize))
        #expect(SettingsTarget(setting: nil, page: "looks") == SettingsTarget(page: .look))
        #expect(SettingsTarget(setting: nil, page: "Backup") == SettingsTarget(page: .backup))
        // A setting wins over the page; an unknown setting falls back to the page.
        #expect(SettingsTarget(setting: "brain_source", page: "look")?.page == .brain)
        #expect(SettingsTarget(setting: "nonsense", page: "moves")?.page == .moves)
        #expect(SettingsTarget(setting: nil, page: nil) == nil)
        #expect(SettingsTarget(setting: "nonsense", page: "nowhere") == nil)
        #expect(SettingsTarget(setting: .backupReset).spoken.contains("cannot change settings yourself"))
        #expect(SettingsTarget(page: .moves).notOnThisDevice.contains("on the Mac"))
    }
}
