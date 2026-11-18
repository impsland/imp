import Foundation
import Testing
@testable import ImpKit

@Suite struct HotkeyTests {
    @Test func displayStrings() {
        #expect(Hotkey(keyCode: 79).displayString == "F18", "Caps Lock's old stand-in is just F18")
        #expect(Hotkey(keyCode: 79, modifiers: Hotkey.shift).displayString == "⇧F18")
        #expect(Hotkey(keyCode: 11, modifiers: Hotkey.control | Hotkey.option).displayString == "⌃⌥B")
        #expect(Hotkey(keyCode: 49, modifiers: Hotkey.command | Hotkey.shift).displayString == "⇧⌘Space")
    }

    @Test func validity() {
        #expect(Hotkey(keyCode: 79).isValidGlobalShortcut)                    // a bare function key
        #expect(!Hotkey(keyCode: 0).isValidGlobalShortcut)                   // bare "A"
        #expect(!Hotkey(keyCode: 0, modifiers: Hotkey.shift).isValidGlobalShortcut)
        #expect(Hotkey(keyCode: 0, modifiers: Hotkey.option).isValidGlobalShortcut)
    }

}

@Suite struct ShortcutTests {
    @Test func anAskNeedsWordsOrTheClipboard() throws {
        var s = Shortcut(name: "Plan", steps: [Step(.ask, value: "  ")])
        #expect(!s.isValid && !s.steps[0].isRunnable)
        s.steps = [Step(.ask, value: "Plan my day.")]
        s.hotkey = Hotkey(keyCode: 79)
        #expect(s.isValid)
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(back == s && !back.steps[0].handsOverClipboard)
        #expect(Step(.ask, clipboard: true).isRunnable)
        #expect(Briefing.shortcut("Plan my day.", clip: nil).content == "Plan my day.")
    }

    @Test func stepsKeepTheirOrderThroughACodableRoundTrip() throws {
        let steps = [Step(.play, value: "Wiggle"), Step(.say, value: "Ouch!"), Step(.sleep), Step(.say, value: "Zzz", aloud: true)]
        let s = Shortcut(name: "Ouch", trigger: Trigger(.poke), steps: steps)
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(back.steps == steps && back.steps.map(\.act) == [.play, .say, .sleep, .say])
        #expect(s.isValid && s.runsLocally)
    }

    @Test func atMostFiveSteps() {
        let six = Array(repeating: Step(.say, value: "x"), count: 6)
        #expect(!Shortcut(name: "A", trigger: Trigger(.poke), steps: six).isValid)
        #expect(Shortcut(name: "A", trigger: Trigger(.poke), steps: Array(six.prefix(5))).isValid)
    }
}
