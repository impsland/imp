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
    @Test func shortcutsSavedBeforeTheClipboardChoiceStillUseIt() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"Translate","isEnabled":true,"prompt":"Into French"}"#
        let s = try JSONDecoder().decode(Shortcut.self, from: Data(old.utf8))
        #expect(s.name == "Translate" && s.usesClipboard && s.isRunnable)
    }

    @Test func anInstructionAloneNeedsWords() throws {
        var s = Shortcut(name: "Plan", prompt: "  ", usesClipboard: false)
        #expect(!s.isRunnable)
        s.prompt = "Plan my day."
        #expect(s.isRunnable)
        let back = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(s))
        #expect(!back.usesClipboard && back == s)
        // Sent as is: no clipboard, no "here's what I copied".
        #expect(Briefing.shortcut(s.prompt, clip: nil).content == "Plan my day.")
    }
}
