import Foundation
import Testing
@testable import Imp

/// The main menu belongs to SwiftUI in an app with the SwiftUI life cycle. The app declares its menus as
/// the scene's commands and never installs one by hand: a hand-made `NSApp.mainMenu` is replaced when
/// SwiftUI next updates its scenes, and the Edit menu went with it, so ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z stopped
/// reaching text fields (the Key field among them).
@Suite struct MenuCommandsTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Imp")

    private static func swiftFiles() -> [URL] {
        (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
    }

    @Test func theSceneDeclaresTheMenusAsCommands() throws {
        let app = try String(contentsOf: Self.sources.appendingPathComponent("App/ImpApp.swift"), encoding: .utf8)
        #expect(app.contains(".commands { ImpCommands("))
    }

    @Test func nothingReplacesTheMainMenuByHand() throws {
        let files = Self.swiftFiles()
        #expect(files.count > 100)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("NSApp.mainMenu ="), "\(file.lastPathComponent) sets the main menu by hand")
        }
    }

    /// A SwiftUI shortcut on ⌘X, ⌘C, ⌘V, ⌘A or ⌘Z is found before the Edit menu, so it takes the key from
    /// every text field in the same window. Only the animation editor's timeline has such keys, and its
    /// text fields are on another page of the sheet.
    @Test func noScreenTakesTheEditingKeysFromItsTextFields() throws {
        let pattern = try NSRegularExpression(pattern: #"\.keyboardShortcut\("[xcvaz]", modifiers: (\.command|\[\.command, \.shift\])\)"#)
        var owners: Set<String> = []
        for file in Self.swiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            if pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil { owners.insert(file.lastPathComponent) }
        }
        #expect(owners == ["AnimationEditor.swift"])
    }
}
