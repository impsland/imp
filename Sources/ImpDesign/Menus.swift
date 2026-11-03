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
    @State private var hover = false

    public init(title: LocalizedStringKey, symbol: String? = nil, maxWidth: CGFloat = 200, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }

    /// For names and text that's already been localized.
    public init(verbatim title: String, symbol: String? = nil, maxWidth: CGFloat = 200, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }

    public var body: some View {
        Menu { content } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                title
                    .font(Typeface.label)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: maxWidth - 50, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Dungeon.muted)
            }
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 10)
            .frame(minHeight: Sizing.hit > 28 ? Sizing.hit : 26)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 2).padding(-3).opacity(focused ? 1 : 0))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
                maxWidth: CGFloat = 200, title: @escaping (Value) -> String) {
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
