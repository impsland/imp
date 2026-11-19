import Foundation
import Testing
import ImpKit
@testable import Imp

/// No setting can be added to a screen without joining the catalog, and none is unreachable.
@Suite struct SettingAnchorTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let sources: [String: String] = {
        // Settings lives in two places: the app-wide and per-Imp pages, and the Devices screen with its Link sheet.
        let files = ["apple/Sources/Imp/UI/Settings", "apple/Sources/Imp/UI/Devices"].flatMap { path in
            (FileManager.default.enumerator(at: repo.appendingPathComponent(path), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        }.filter { $0.pathExtension == "swift" }
        return Dictionary(uniqueKeysWithValues: files.compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
        })
    }()

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    @Test func everySettingIsAnchoredExactlyOnce() {
        #expect(Self.sources.count > 20)
        let anchored = Self.sources.values.flatMap { Self.matches(#"\.settingAnchor\(\.(\w+)\)"#, in: $0) }
        for setting in SettingID.allCases {
            let name = String(describing: setting)
            #expect(anchored.filter { $0 == name }.count == 1, "\(setting.rawValue) must have exactly one .settingAnchor(.\(name))")
        }
        #expect(anchored.count == SettingID.allCases.count, "an anchor names something that is not a setting")
    }

    @Test func everySettingRowIsInTheCatalog() {
        let titles = Set(SettingID.allCases.map(\.titleKey))
        let files = ["AppPane", "BubblePane", "TalkingPane", "BrainsPane", "SharingPane", "BackupPane", "ServerRows", "DevicesScreen", "ThisMacPage", "LinkedDevicePage", "HopSheet", "LinkDeviceSheet", "PermissionsPage", "BrainPanel", "MemoryCard",
                     "PersonalityPanel", "LookPanel", "ToolsPanel", "AnimationsPanel", "TriggersPanel"]
        for file in files {
            let source = Self.sources[file + ".swift"] ?? ""
            #expect(!source.isEmpty, "\(file) not found")
            for key in Self.matches(#"\bRow\((?:LocalizedStringKey\()?"([^"]+)""#, in: source) {
                #expect(titles.contains(key), "\(file): Row \"\(key)\" is not a setting in SettingsCatalog: add a SettingID and a .settingAnchor")
            }
        }
    }

    @Test func settingsLinksParse() throws {
        guard case .settings(let one?) = try #require(URLCommand("imp://settings?setting=look_colour&imp=Pip")) else {
            Issue.record("no target"); return
        }
        #expect(one == SettingsTarget(page: .look, setting: .lookColour, imp: "Pip"))
        guard case .settings(let two?) = try #require(URLCommand("imp://settings?page=backup")) else {
            Issue.record("no target"); return
        }
        #expect(two == SettingsTarget(page: .backup))
        guard case .settings(let none) = try #require(URLCommand("imp://settings")) else { return }
        #expect(none == nil)
    }
}
