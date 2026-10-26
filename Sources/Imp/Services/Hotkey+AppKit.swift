import AppKit
import Carbon.HIToolbox
import ImpKit

extension Hotkey {
    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & Hotkey.control != 0 { f.insert(.control) }
        if modifiers & Hotkey.option != 0 { f.insert(.option) }
        if modifiers & Hotkey.shift != 0 { f.insert(.shift) }
        if modifiers & Hotkey.command != 0 { f.insert(.command) }
        return f
    }

    /// The menu key equivalent that displays this shortcut.
    var keyEquivalent: String? {
        let code = Int(keyCode)
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let i = functionKeys.firstIndex(of: code) { return String(UnicodeScalar(NSF1FunctionKey + i)!) }
        let special: [Int: Int] = [
            kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
            kVK_ForwardDelete: NSDeleteFunctionKey, kVK_LeftArrow: NSLeftArrowFunctionKey,
            kVK_RightArrow: NSRightArrowFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey,
            kVK_DownArrow: NSDownArrowFunctionKey, kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
            kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey, kVK_ANSI_KeypadEnter: 0x03,
        ]
        if let scalar = special[code].flatMap(UnicodeScalar.init) { return String(scalar) }
        let name = KeyNames.name(for: keyCode)
        return name.count == 1 ? name.lowercased() : nil
    }
}
