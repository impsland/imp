import SwiftUI

/// One picture for each state an Imp can be in, the same on every platform, so a state reads without
/// words (principle 8). The words stay as the help and the screen reader's label.
public enum ImpStateSymbol {
    /// At home: in the app's window, not out on the desktop.
    public static let home = "house.fill"
    /// Out on the desktop, awake.
    public static let out = "sparkles"
    /// Out but hidden.
    public static let hidden = "eye.slash.fill"
    /// Asleep: its home is away, or it has no Brain.
    public static let asleep = "moon.zzz.fill"
    /// It has no Brain to think with.
    public static let noBrain = "lightbulb.slash.fill"
    /// It lives on this phone.
    public static let phone = "iphone"
}

/// A state as a small picture: the word is its help and what a screen reader says.
public struct StateMark: View {
    let label: Text
    let symbol: String
    var color: Color

    public init(_ label: LocalizedStringKey, symbol: String, color: Color = Tone.muted) {
        self.label = Text(label); self.symbol = symbol; self.color = color
    }

    public init(verbatim label: String, symbol: String, color: Color = Tone.muted) {
        self.label = Text(verbatim: label); self.symbol = symbol; self.color = color
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.icon(.small))
            .foregroundStyle(color)
            .help(label)
            .accessibilityLabel(label)
    }
}
