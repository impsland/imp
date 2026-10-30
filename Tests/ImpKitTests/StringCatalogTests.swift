import Testing
import Foundation

/// Checks Resources/Localization/Localizable.xcstrings, the app's String Catalog.
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
            .deletingLastPathComponent().appendingPathComponent("Resources/Localization/Localizable.xcstrings")
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
            let expected = Self.specifiers(key)
            for (language, localization) in entry.localizations ?? [:] {
                for text in localization.values {
                    let found = Self.specifiers(text)
                    let ok = localization.isPlural ? Set(found).isSubset(of: Set(expected)) : found == expected
                    #expect(ok, "\(language): \(key) → \(text)")
                }
            }
        }
    }
}
