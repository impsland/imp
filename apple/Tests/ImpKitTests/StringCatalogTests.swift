import Testing
import Foundation

/// Checks apple/Resources/Localization/Localizable.xcstrings, the app's String Catalog.
@Suite struct StringCatalogTests {
    private struct Catalog: Decodable { let strings: [String: Entry] }
    private struct Entry: Decodable {
        let extractionState: String?
        let localizations: [String: Localization]?
    }
    private struct Localization: Decodable {
        struct Unit: Decodable { let value: String }
        let stringUnit: Unit?
        let variations: [String: [String: Localization]]?   // plural / device → case → text
        var isPlural: Bool { variations != nil }
        /// The plain text, or each variation's.
        var values: [String] {
            (stringUnit.map { [$0.value] } ?? []) + (variations ?? [:]).values.flatMap { $0.values.flatMap(\.values) }
        }
    }

    private static let catalog: [String: Entry] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("apple/Resources/Localization/Localizable.xcstrings")
        return (try? JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url)))?.strings ?? [:]
    }()

    /// Format specifiers as (position, type): `%lld`, `%2$@`…
    private static func specifiers(_ s: String) -> [String] {
        let regex = /%(?:(\d+)\$)?(lld|ld|d|@|f|\.\d+f)/
        return s.matches(of: regex).enumerated().map { i, m in "\(m.1.map { String($0) } ?? String(i + 1)):\(m.2)" }.sorted()
    }

    @Test func loads() { #expect(Self.catalog.count > 100) }

    /// Plurals come from plural variations. `^[…](inflect: true)` only works in SwiftUI's own Text
    /// for a few languages; `String(localized:)` shows the markup as is.
    @Test func noInflectionMarkup() {
        for (key, entry) in Self.catalog {
            let texts = [key] + (entry.localizations ?? [:]).values.flatMap(\.values)
            #expect(!texts.contains { $0.contains("](inflect:") }, "\(key)")
        }
    }

    /// A translation uses the key's arguments (a plural's "one" form may leave the number out).
    @Test func translationsKeepTheArguments() {
        for (key, entry) in Self.catalog where entry.extractionState != "stale" {
            // A manual key is a name, so its arguments come from the English text.
            let english = entry.localizations?["en"]?.values.first
            let expected = Self.specifiers(entry.extractionState == "manual" ? english ?? key : key)
            for (language, localization) in entry.localizations ?? [:] {
                for text in localization.values {
                    let found = Self.specifiers(text)
                    let ok = localization.isPlural ? Set(found).isSubset(of: Set(expected)) : found == expected
                    #expect(ok, "\(language): \(key) → \(text)")
                }
            }
        }
    }

    // MARK: Strings from design/strings

    private static let languages = ["en", "es", "zh-Hans"]

    private struct Source: Decodable {
        let en: Text
        let es: Text
        let zhHans: Text
        enum CodingKeys: String, CodingKey { case en, es, zhHans = "zh-Hans" }
        var all: [Text] { [en, es, zhHans] }
    }

    /// One language's text: a plain string or the forms of a plural.
    private enum Text: Decodable {
        case plain(String)
        case plural([String: String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .plain(s) } else { self = .plural(try c.decode([String: String].self)) }
        }
    }

    /// Every key in design/strings, with its three texts.
    private static let sources: [String: Source] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("design/strings")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var all: [String: Source] = [:]
        for file in files where file.pathExtension == "json" {
            let entries = (try? JSONDecoder().decode([String: Source].self, from: Data(contentsOf: file))) ?? [:]
            all.merge(entries) { first, _ in first }
        }
        return all
    }()

    @Test func sourceStringsLoad() { #expect(Self.sources.count > 100) }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The terminal app's table, cli/src/strings.generated.rs: the only place the `cli.*` keys are generated into.
    private static let terminalTable: String = {
        (try? String(contentsOf: root.appendingPathComponent("cli/src/strings.generated.rs"), encoding: .utf8)) ?? ""
    }()

    /// The keys of the extension's chrome.i18n messages for one language folder (underscores for dots).
    private static func extensionMessages(_ folder: String) -> Set<String> {
        let url = root.appendingPathComponent("extension/_locales/\(folder)/messages.json")
        let messages = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))) ?? [:]
        return Set(messages.keys)
    }

    /// Every key of design/strings is in the output it is generated into, with all three languages filled in:
    /// `cli.*` in the terminal app's Rust table, every other key in the catalog (marked manual), and `extension.*`
    /// also in each language of the extension's _locales.
    @Test func everySourceKeyHasAllThreeLanguages() {
        let extensionKeys = ["en", "es", "zh_CN"].map(Self.extensionMessages)
        #expect(!Self.terminalTable.isEmpty, "cli/src/strings.generated.rs is missing. Run node design/generate.mjs.")
        for key in Self.sources.keys.sorted() {
            if key.hasPrefix("cli.") {
                #expect(Self.terminalTable.contains("(\"\(key)\", ["), "\(key) is missing from cli/src/strings.generated.rs. Run node design/generate.mjs.")
                for source in [Self.sources[key]!.en, Self.sources[key]!.es, Self.sources[key]!.zhHans] {
                    if case .plain(let text) = source { #expect(!text.isEmpty, "\(key)") } else { Issue.record("\(key): the terminal app has no plurals") }
                }
                continue
            }
            if key.hasPrefix("extension.") {
                for keys in extensionKeys {
                    #expect(keys.contains(key.replacingOccurrences(of: ".", with: "_")), "\(key) is missing from extension/_locales")
                }
            }
            guard let entry = Self.catalog[key] else {
                Issue.record("\(key) is missing from the catalog. Run node design/generate.mjs.")
                continue
            }
            #expect(entry.extractionState == "manual", "\(key)")
            for language in Self.languages {
                let texts = entry.localizations?[language]?.values ?? []
                #expect(!texts.isEmpty && !texts.contains(""), "\(language): \(key)")
            }
        }
    }

    /// A keyed (manual) catalog entry exists only when design/strings has it, so a removed key leaves no orphan.
    @Test func noManualKeyWithoutASource() {
        for (key, entry) in Self.catalog where entry.extractionState == "manual" {
            #expect(Self.sources[key] != nil, "\(key) is in the catalog but not in design/strings")
            #expect(!key.hasPrefix("cli."), "\(key) is terminal-only and must not be in the app catalog")
        }
    }

    /// The three languages of a key use the same arguments and the same shape (plain or plural).
    @Test func sourceTextsMatchAcrossLanguages() {
        for (key, source) in Self.sources {
            let shapes = source.all.map { text -> Bool in if case .plural = text { true } else { false } }
            #expect(Set(shapes).count == 1, "\(key) is plural in some languages only")
        }
    }
}
