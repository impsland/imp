import SwiftUI

/// A pop-up menu that keeps to its size: an icon and a title that's cut short with "…" rather
/// than pushing the form (or the whole sheet) wider.
public struct CompactMenu<Content: View>: View {
    let title: Text
    var symbol: String?
    var maxWidth: CGFloat
    var content: Content
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @Environment(\.controlPlacement) private var placement
    @State private var hover = false

    public init(title: LocalizedStringKey, symbol: String? = nil, maxWidth: CGFloat = Sizing.menuTitle, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }

    /// For names and text that's already been localized.
    public init(verbatim title: String, symbol: String? = nil, maxWidth: CGFloat = Sizing.menuTitle, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }

    private var fills: Bool { placement == .under }

    public var body: some View {
        Menu { content } label: {
            HStack(spacing: Spacing.snug) {
                if let symbol {
                    Image(systemName: symbol).font(.icon(.medium)).foregroundStyle(LegibleTint(tint))
                }
                title
                    .font(Typeface.label)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: fills ? .infinity : maxWidth, alignment: .leading)
                    .fixedSize(horizontal: !fills, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.icon(.tiny, weight: .bold)).foregroundStyle(Tone.muted)
            }
            .foregroundStyle(Tone.text)
            .padding(.horizontal, Spacing.medium)
            .frame(maxWidth: fills ? .infinity : nil, minHeight: Sizing.control)
            .background(Capsule().fill(hover ? Tone.cardHover : Tone.card))
            .focusRing(Capsule(), shown: focused)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fills, vertical: true)
        .onHover { hover = $0 }
        .impAnimation(value: hover)
        .help(title)
    }
}

/// A picker shown as a pop-up menu in the app's look. The menu lists the options with a tick on
/// the chosen one, and the button shows its title. It is a real `Picker` inside, so VoiceOver and
/// the keyboard treat it as one.
public struct ImpPicker<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var symbol: String?
    var maxWidth: CGFloat

    /// `title` names an option. Names are data and are shown as they are, so localize them first.
    public init(_ label: LocalizedStringKey, selection: Binding<Value>, options: [Value], symbol: String? = nil,
                maxWidth: CGFloat = Sizing.menuTitle, title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.symbol = symbol
        self.maxWidth = maxWidth
        self.title = title
    }

    public var body: some View {
        CompactMenu(verbatim: title(selection), symbol: symbol, maxWidth: maxWidth) {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(verbatim: title(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}
