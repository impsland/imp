import Foundation
import Testing

/// The whole app wears the design system (docs/DESIGN.md). These system styles would bring the
/// default look back, so no Mac UI file and no iPhone file may use them. Alerts, confirmation
/// dialogs, share sheets, file panels, context menu items and the navigation bar stay system on
/// purpose, and none of those needs a banned style.
@Suite struct AppStyleTests {
    /// Patterns for the system looks. `Stepper(` is matched as a whole word so `ImpStepper(` passes.
    private static let banned: [String] = [
        #"\.buttonStyle\(\s*\.(bordered|borderedProminent|borderless)\b"#,
        #"\.borderedProminent\b"#,
        #"\.toggleStyle\(\s*\.(switch|checkbox|button)\b"#,
        #"\.pickerStyle\(\s*\.(segmented|menu|wheel|inline|radioGroup|navigationLink|palette)\b"#,
        #"\.menuStyle\(\s*\.borderlessButton"#,
        #"\.textFieldStyle\(\s*\.(roundedBorder|squareBorder)"#,
        #"\.listStyle\(\s*\.(?!plain\b)"#,  // .plain is the bare list the model picker re-dresses with impListRow
        #"(?<![A-Za-z])Stepper\("#,
        #"(?<![A-Za-z])DatePicker\("#,
        #"(?<![A-Za-z])Form\s*\{"#,
    ]

    /// Files left out, each with the reason. None today: add one only with a reason beside it.
    private static let allowed: Set<String> = []

    /// Every iPhone screen root and the file it lives in. Each file must apply `.impControls(`,
    /// so a button or switch added later without a style still wears the app's look.
    private static let iPhoneRoots: [String: String] = [
        "ImpPhoneApp.swift": "the app root (stage, games, status pill)",
        "DevicesSheet.swift": "DevicesSheet",
        "PairingView.swift": "PairingView, InviteSheet and the scanner",
        "ChatSheet.swift": "ChatSheet",
        "Talks.swift": "TalksSheet",
        "ShakeSend.swift": "the Undo bar and the Shake to send card",
        "PocketEditor.swift": "Hatch and Edit an Imp",
    ]

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(_ path: String) -> [URL] {
        let root = repo.appendingPathComponent(path)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Code with whole-line comments and trailing `//` comments taken out.
    private static func codeLines(_ source: String) -> [(Int, String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { number, line in
            var code = String(line)
            if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
            if let slashes = code.range(of: " //") { code = String(code[..<slashes.lowerBound]) }
            return (number + 1, code)
        }
    }

    @Test func noSystemControlStylesAnywhere() throws {
        let files = (Self.swiftFiles("Sources/Imp/UI") + Self.swiftFiles("iOS/Imp"))
            .filter { !Self.allowed.contains($0.lastPathComponent) }
        #expect(files.count > 40)
        let patterns = try Self.banned.map { try NSRegularExpression(pattern: $0) }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, code) in Self.codeLines(source) {
                let range = NSRange(code.startIndex..., in: code)
                for (pattern, regex) in zip(Self.banned, patterns) where regex.firstMatch(in: code, range: range) != nil {
                    Issue.record("\(file.lastPathComponent):\(number) uses a system style (\(pattern))")
                }
            }
        }
    }

    @Test func iPhoneScreenRootsApplyImpControls() throws {
        for (name, what) in Self.iPhoneRoots {
            let file = Self.repo.appendingPathComponent("iOS/Imp/\(name)")
            let source = try String(contentsOf: file, encoding: .utf8)
            let applies = Self.codeLines(source).contains { $0.1.contains(".impControls(") }
            #expect(applies, "\(name) (\(what)) must apply .impControls(tint:)")
        }
    }
}
