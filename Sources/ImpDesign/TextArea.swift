import SwiftUI

/// A multi-line text field in the app's look: the same well, edge, radius and font as `.impField()`.
/// It starts `minLines` tall, grows with what is typed up to `maxLines`, then scrolls. The
/// placeholder is the field's own prompt in the muted colour, so it sits where the text starts and
/// goes away with the first character. Type scales with Dynamic Type. Put `.focused(...)` on it as
/// on any field.
public struct TextArea: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var minLines: Int
    var maxLines: Int
    var mono: Bool
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    /// `title` names the field for VoiceOver.
    public init(_ title: LocalizedStringKey, text: Binding<String>, placeholder: LocalizedStringKey = "",
                minLines: Int = 2, maxLines: Int = 6, mono: Bool = false) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.minLines = max(1, minLines)
        self.maxLines = max(minLines, maxLines)
        self.mono = mono
    }

    private var font: Font { mono ? Typeface.mono : Typeface.body }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.small, style: .continuous) }

    public var body: some View {
        // The prompt is the only placeholder: the title names the field for VoiceOver and is not shown.
        TextField(text: $text, prompt: Text(placeholder).foregroundStyle(Dungeon.muted), axis: .vertical) { Text(title) }
            .textFieldStyle(.plain)
            .font(font)
            .lineLimit(minLines...maxLines)
            .focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(minHeight: Sizing.control, alignment: .topLeading)
            .background(shape.fill(Dungeon.well))
            .overlay(shape.strokeBorder(focused ? tint.opacity(0.85) : Dungeon.cardEdge, lineWidth: focused ? 1.5 : 1))
            .contentShape(shape)
            .onTapGesture { focused = true }
            .impAnimation(value: focused)
    }
}
