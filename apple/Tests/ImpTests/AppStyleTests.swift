import Foundation
import Testing

/// The whole app wears the design system (docs/design/index.md). These system styles would bring the
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
        "PairingView.swift": "the first screen, the link sheet and the scanner",
        "ChatSheet.swift": "ImpSheet, an Imp's chat and talks",
        "Talks.swift": "TalksPane, the talks side of an Imp's sheet",
        "ShakeSend.swift": "the Undo bar and the Shake to send card",
        "PocketEditor.swift": "Hatch and Edit an Imp",
        "OnboardingPhone.swift": "the first run, waking an Imp with a Brain",
    ]

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

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
        let files = (Self.swiftFiles("apple/Sources/Imp/UI") + Self.swiftFiles("apple/iOS/Imp"))
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

    /// Values that belong to the design system (design/tokens.json): a literal font size, colour,
    /// corner, gap, fixed frame or animation in screen code means a token was skipped. Shrinking text
    /// to fit is banned too: a crowded row switches to icons instead (`FitLabel`).
    private static let literals: [(String, String)] = [
        (#"\.system\(size:\s*[0-9]"#, "a literal font size (use Typeface or .icon)"),
        (#"cornerRadius:\s*[0-9]"#, "a literal corner radius (use Radius)"),
        (#"\.padding\((\.[a-zA-Z]+,\s*)?-?[1-9][0-9.]*\)"#, "a literal padding (use Spacing)"),
        (#"spacing:\s*[1-9]"#, "a literal spacing (use Spacing)"),
        (#"Color\((red|white|hue):"#, "a literal colour (use Tone)"),
        (#"(Color|NSColor|UIColor)\.(white|black|red|orange|green|yellow|blue|gray|purple|pink)\b"#, "a system colour (use Tone)"),
        (#"\.(foregroundStyle|foregroundColor|fill|tint)\(\.(white|black|red|orange|green|yellow|blue|gray|secondary|tertiary)\)"#, "a system colour (use Tone)"),
        (#"\.frame\([^)]*\b(width|height|minWidth|minHeight|maxWidth|maxHeight|idealWidth|idealHeight):\s*[1-9]"#, "a literal size (use Sizing or a flexible layout)"),
        (#"\.animation\(\.(easeOut|easeIn|easeInOut|linear|spring|snappy|smooth|bouncy)"#, "a literal animation (use .impAnimation)"),
        (#"withAnimation\(\.(easeOut|easeIn|easeInOut|linear|spring|snappy|smooth|bouncy)"#, "a literal animation (use withImpAnimation)"),
        (#"minimumScaleFactor"#, "text shrunk to fit (switch to an icon form instead)"),
    ]

    /// Files that draw pictures rather than lay out controls keep their own numbers. Each with its reason.
    private static let drawings: [String: String] = [
        "Contrast.swift": "pure colour maths (black and white as numbers, no view): `ContrastColor(red:...)` is not a screen colour",
        "OnboardingPictures.swift": "the first run's pictures are drawings: their sizes are those of the picture, not of a control",
    ]

    /// A `MarkdownView` loads its pictures only when told what to do once one has loaded (`onImageLoad`): without
    /// it, it is being measured. A screen that leaves it out never shows its pictures (the talk sheet did).
    @Test func everyMarkdownViewSaysWhatAPictureLoadingDoes() throws {
        var missing: [String] = []
        for file in Self.swiftFiles("apple/Sources/Imp/UI") where file.lastPathComponent != "MarkdownView.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            var rest = source[...]
            while let start = rest.range(of: "MarkdownView(") {
                // The call's arguments: up to the parenthesis that closes it.
                var depth = 0, end = start.upperBound
                for i in source[start.lowerBound...].indices {
                    if source[i] == "(" { depth += 1 } else if source[i] == ")" { depth -= 1; if depth == 0 { end = i; break } }
                }
                let line = source[..<start.lowerBound].filter { $0 == "\n" }.count + 1
                if !source[start.lowerBound..<end].contains("onImageLoad") { missing.append("\(file.lastPathComponent):\(line)") }
                rest = source[end...]
            }
        }
        #expect(missing.isEmpty, "MarkdownView without onImageLoad (its pictures never load): \(missing)")
    }

    /// A Mac sheet that shows nothing can't be closed (it has no Cancel and no close button) and holds its window,
    /// the app's quit included. So what a sheet shows is never wrapped in a bare `if`: decide whether it is up in
    /// its `isPresented`/`item` binding instead. (An iPhone sheet can always be swiped away.)
    @Test func aMacSheetIsNeverEmpty() throws {
        var found: [String] = []
        for file in Self.swiftFiles("apple/Sources/Imp/UI") {
            let source = try String(contentsOf: file, encoding: .utf8)
            var rest = source[...]
            while let start = rest.range(of: ".sheet(") {
                // The call's arguments, up to the parenthesis that closes them. The content is the closure after.
                var depth = 0, end = start.upperBound
                for i in source[start.lowerBound...].indices {
                    if source[i] == "(" { depth += 1 } else if source[i] == ")" { depth -= 1; if depth == 0 { end = i; break } }
                }
                var body = source[source.index(after: end)...].drop { $0 == " " }
                if body.first == "{" {
                    body = body.dropFirst()
                    // Past `item in`, blank lines and comments, to the first statement.
                    if let inRange = body.prefix(80).range(of: " in"), !body[..<inRange.lowerBound].contains("\n") {
                        body = body[inRange.upperBound...]
                    }
                    var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    lines.removeAll { $0.isEmpty || $0.hasPrefix("//") }
                    if let first = lines.first, first.hasPrefix("if ") {
                        found.append("\(file.lastPathComponent):\(source[..<start.lowerBound].filter { $0 == "\n" }.count + 1)")
                    }
                }
                rest = source[end...]
            }
        }
        #expect(found.isEmpty, "A sheet whose content is a bare `if` can open empty and lock the window: \(found)")
    }

    @Test func screensTakeTheirValuesFromTokens() throws {
        let files = (Self.swiftFiles("apple/Sources/Imp/UI") + Self.swiftFiles("apple/Sources/ImpDesign") + Self.swiftFiles("apple/iOS/Imp"))
            .filter { !$0.lastPathComponent.hasSuffix(".generated.swift") && Self.drawings[$0.lastPathComponent] == nil }
        #expect(files.count > 60)
        let patterns = try Self.literals.map { (try NSRegularExpression(pattern: $0.0), $0.1) }
        var found: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, code) in Self.codeLines(source) {
                let range = NSRange(code.startIndex..., in: code)
                for (regex, what) in patterns where regex.firstMatch(in: code, range: range) != nil {
                    found.append("\(file.lastPathComponent):\(number) has \(what)")
                }
            }
        }
        #expect(found.isEmpty, "\(found.count) literal values:\n\(found.prefix(60).joined(separator: "\n"))")
    }

    /// The bug class behind dark-on-dark and light-on-light text: a foreground that assumes the ground.
    /// An Imp's colour as a foreground goes through `LegibleTint`, text on a fill through `OnTint`, and
    /// fixed colours through the tokens (`Tone.paper` and `Tone.ink` over a picture or a scrim).
    private static let foregrounds: [(String, String)] = [
        (#"\.foreground(Style|Color)\(\s*(tint|imp\.tint|impTint|accent|Color\.imp\()"#, "a raw Imp tint as a foreground (use LegibleTint)"),
        (#"\.foregroundColor\("#, "foregroundColor (use foregroundStyle with a token, OnTint or LegibleTint)"),
        (#"\.(foregroundStyle|fill|background|tint)\(\s*(Color)?\.(white|black|primary|secondary|tertiary|quaternary)\b"#,
         "a system shape style that assumes a ground (use Tone, OnTint or LegibleTint)"),
    ]

    /// The white or black on a coloured control and the fill under it come from one rule
    /// (`Contrast.control`), as `OnTint` and `TintFill`. A screen that draws `OnTint` on anything else
    /// would not follow the person's choice, or would lose it on a light colour.
    @Test func whatIsDrawnOnAColourSitsOnATintFill() throws {
        let files = Self.swiftFiles("apple/Sources/Imp/UI") + Self.swiftFiles("apple/Sources/ImpDesign") + Self.swiftFiles("apple/iOS/Imp")
        var users = 0
        for file in files where file.lastPathComponent != "Tokens.swift" {
            let code = Self.codeLines(try String(contentsOf: file, encoding: .utf8)).map(\.1).joined(separator: "\n")
            let onTint = code.components(separatedBy: "OnTint(").count - 1
            let fills = code.components(separatedBy: "TintFill(").count - 1
            if onTint > 0 { users += 1 }
            #expect(onTint == 0 || fills > 0, "\(file.lastPathComponent) draws OnTint with no TintFill under it")
        }
        #expect(users > 10)
    }

    @Test func screensNeverAssumeTheGroundOfAForeground() throws {
        let files = Self.swiftFiles("apple/Sources/Imp/UI") + Self.swiftFiles("apple/iOS/Imp")
        #expect(files.count > 40)
        let patterns = try Self.foregrounds.map { (try NSRegularExpression(pattern: $0.0), $0.1) }
        var found: [String: [Int]] = [:]
        var what: [String: String] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, code) in Self.codeLines(source) {
                let range = NSRange(code.startIndex..., in: code)
                for (regex, why) in patterns where regex.firstMatch(in: code, range: range) != nil {
                    found[file.lastPathComponent, default: []].append(number)
                    what[file.lastPathComponent, default: ""] = why
                }
            }
        }
        let lines = found.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value.count) (lines \($0.value.prefix(6).map(String.init).joined(separator: ", "))): \(what[$0.key] ?? "")" }
        #expect(found.isEmpty, "\(found.values.map(\.count).reduce(0, +)) foregrounds that assume their ground:\n\(lines.joined(separator: "\n"))")
    }

    @Test func iPhoneScreenRootsApplyImpControls() throws {
        for (name, what) in Self.iPhoneRoots {
            let file = try #require(Self.swiftFiles("apple/iOS/Imp").first { $0.lastPathComponent == name }, "\(name) is not in apple/iOS/Imp")
            let source = try String(contentsOf: file, encoding: .utf8)
            let applies = Self.codeLines(source).contains { $0.1.contains(".impControls(") }
            #expect(applies, "\(name) (\(what)) must apply .impControls(tint:)")
        }
    }

    /// One rule of the Pebble language: a pattern screen code may not contain, and the files that may,
    /// each with the reason (a real drawing, a system menu, something that floats).
    private struct Rule {
        let pattern: String
        let what: String
        var allowed: [String: String] = [:]
    }

    private static let pebble: [Rule] = [
        Rule(pattern: #"\.strokeBorder\(|\.stroke\("#, what: "an outline (only focus rings and drawings may stroke)", allowed: [
            "Adaptive.swift": "the keyboard focus ring",
            "DevicePlugs.swift": "a plug is a drawing: its outline is what shows it is out",
            "OnboardingPictures.swift": "the outlines of a screen and a device in the first run's pictures are drawings",
            "Inputs.swift": "a focused field's ring",
            "TextArea.swift": "a focused field's ring",
            "BeatTrack.swift": "the timeline track is a drawing",
            "AnimationStage.swift": "the timeline is a drawing",
            "AnimationEditor.swift": "the timeline is a drawing",
            "PairingView.swift": "the dashed scan frame",
            "Shutter.swift": "the camera's shutter ring is a drawing of a camera button",
            "GameLayer.swift": "game canvas", "GameRound.swift": "game canvas", "EmbersCoach.swift": "game canvas",
            "EchoLayer.swift": "game canvas", "EchoCoach.swift": "game canvas",
        ]),
        Rule(pattern: #"Divider\(\)"#, what: "a divider", allowed: ["CanvasMenus.swift": "inside real system menus"]),
        Rule(pattern: #"LinearGradient|RadialGradient|AngularGradient|\.gradient\b"#, what: "a gradient", allowed: [
            "LookPanel.swift": "a colour-spectrum picker",
            "PocketEditor.swift": "a colour-spectrum picker",
            "MediaPlayer.swift": "the voice smoke orb",
            "SpeechMedia.swift": "the voice smoke orb",
            "VoicePresence.swift": "the voice orb",
            "GameLayer.swift": "game canvas", "GameRound.swift": "game canvas", "EmbersCoach.swift": "game canvas",
            "EchoLayer.swift": "game canvas", "EchoCoach.swift": "game canvas",
        ]),
        Rule(pattern: #"NSVisualEffectView|\.background\(\.(ultraThin|thin|regular|thick|ultraThick|bar)?Material|\bMaterial\b"#, what: "a blurred material", allowed: ["BubbleBlur.swift": "the bubble's behind-window blur, masked to its shape and tail"]),
        Rule(pattern: #"repeatForever"#, what: "an endless animation", allowed: ["Energy.swift": "the breath and the float of an Imp at rest"]),
        Rule(pattern: #"\bDungeon|EmberButtonStyle|CardDivider|buttonText"#, what: "a name of the old language"),
        Rule(pattern: #"\.shadow\("#, what: "a shadow (only things that float over content)", allowed: [
            "Notice.swift": "the floating notice sits over content",
            "DevicePlugs.swift": "a plugged-in plug glows",
            "BubbleChrome.swift": "the desktop bubble and its tail float",
            "VoicePresence.swift": "the voice orb",
            "MediaPlayer.swift": "the voice smoke orb",
            "SpeechBubble.swift": "the phone bubble floats",
            "DoorSigns.swift": "signs float over the desktop",
            "ImpMarks.swift": "the undo bar floats",
            "AnimationStage.swift": "the stage's timeline drawing",
            "BeatTrack.swift": "a dragged beat floats",
            "GameResults.swift": "the results card floats over the game and the close glyph has a halo",
            "GameLayer.swift": "game canvas", "GameRound.swift": "game canvas", "EmbersCoach.swift": "game canvas",
            "EchoLayer.swift": "game canvas", "EchoCoach.swift": "game canvas",
        ]),
    ]

    @Test func screensWearThePebbleLanguage() throws {
        let files = (Self.swiftFiles("apple/Sources/Imp/UI") + Self.swiftFiles("apple/Sources/ImpDesign") + Self.swiftFiles("apple/iOS/Imp"))
            .filter { !$0.lastPathComponent.hasSuffix(".generated.swift") }
        let rules = try Self.pebble.map { (try NSRegularExpression(pattern: $0.pattern), $0) }
        var found: [String] = []
        for file in files {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, code) in Self.codeLines(source) {
                let range = NSRange(code.startIndex..., in: code)
                for (regex, rule) in rules where rule.allowed[name] == nil && regex.firstMatch(in: code, range: range) != nil {
                    found.append("\(name):\(number) has \(rule.what)")
                }
            }
            // A segmented control always names an icon for each choice, so it can fall back to icons.
            let code = Self.codeLines(source).map(\.1).joined(separator: "\n")
            var from = code.startIndex
            while let hit = code.range(of: "ImpSegmented(", range: from..<code.endIndex) {
                from = hit.upperBound
                var depth = 1, end = hit.upperBound
                while end < code.endIndex, depth > 0 {
                    if code[end] == "(" { depth += 1 } else if code[end] == ")" { depth -= 1 }
                    end = code.index(after: end)
                }
                if !code[hit.upperBound..<end].contains("symbol:") {
                    let line = code[..<hit.lowerBound].filter { $0 == "\n" }.count + 1
                    found.append("\(name):~\(line) has an ImpSegmented without symbol:")
                }
            }
        }
        #expect(found.isEmpty, "\(found.count) breaks of the language:\n\(found.prefix(80).joined(separator: "\n"))")
    }
}
