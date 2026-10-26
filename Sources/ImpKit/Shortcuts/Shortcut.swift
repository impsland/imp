import Foundation

/// A shortcut: **press these keys → this Imp does what `prompt` says**, with whatever you copied
/// (text or a picture) unless it's set to send the instruction alone. The Imp's model decides
/// how: it answers, and runs commands with its tools when the job needs them.
public struct Shortcut: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var isEnabled = true
    public var hotkey: Hotkey?
    /// What to do, in plain words. Empty (with the clipboard): the Imp just responds to what you copied.
    public var prompt: String
    /// Which Imp does this. `nil` = whichever Imp you talked to last.
    public var performer: UUID?

    /// Sends what's on the clipboard along with the instruction. Off: the instruction alone.
    public var usesClipboard: Bool {
        get { clipboard ?? true }
        set { clipboard = newValue }
    }
    /// Optional, so shortcuts saved before it existed still load (they used the clipboard).
    private var clipboard: Bool?

    /// Can run: it has something to send (what you copied, or an instruction).
    public var isRunnable: Bool { usesClipboard || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init(name: String, isEnabled: Bool = true, hotkey: Hotkey? = nil, prompt: String, performer: UUID? = nil,
                usesClipboard: Bool = true) {
        self.name = name
        self.isEnabled = isEnabled
        self.hotkey = hotkey
        self.prompt = prompt
        self.performer = performer
        self.clipboard = usesClipboard
    }
}

/// What you hand an Imp to work on: something you copied, pasted into its text box, or said.
public enum Clip: Equatable, Sendable {
    case text(String)
    case image(EncodedImage)
}
