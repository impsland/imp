import SwiftUI

// Controls that keep their words on one line. When a row has room they show an icon and a title.
// When it does not, they turn into the icon alone, with the title as the tooltip and the spoken
// label. A title is never shrunk, cut short or wrapped onto a second line.

/// A label that shows its icon and title when they fit, and only the icon when they do not. Use it
/// as a button's or a menu's label: `Button(action:) { FitLabel("Check", systemImage: "checkmark") }`.
public struct FitLabel: View {
    let title: Text
    let systemImage: String

    public init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = Text(title)
        self.systemImage = systemImage
    }

    public init(verbatim title: String, systemImage: String) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            Label { title.lineLimit(1).fixedSize() } icon: { Image(systemName: systemImage) }
            Label { title } icon: { Image(systemName: systemImage) }
                .labelStyle(.iconOnly)
                .help(title)
        }
    }
}

/// The small round bead behind a card's, a row's or a sheet's icon, in the Imp's colour. The icon
/// is always inset from the bead's edge: the bead is at least the icon plus padding on every side.
public struct IconTile: View {
    let systemName: String
    var filled: Bool
    var side: CGFloat
    @Environment(\.impTint) private var tint

    /// `filled` paints the bead with the Imp's colour (a sheet's header). Otherwise the bead is a
    /// soft wash of the colour and the icon is in the colour.
    public init(systemName: String, filled: Bool = false, side: CGFloat = Sizing.iconTile) {
        self.systemName = systemName
        self.filled = filled
        self.side = side
    }

    public var body: some View {
        // The picture is scaled into the middle half of the bead, so no symbol, however wide, can
        // reach the bead's edge.
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(filled ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(tint))
            .padding(side / 4)
            .frame(width: side, height: side)
            .background(Circle().fill(filled ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(tint.opacity(Opacity.tintFill))))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The keyboard focus ring around a control of `shape`, in the Imp's colour.
    public func focusRing<S: InsettableShape>(_ shape: S, shown: Bool) -> some View {
        modifier(FocusRing(shape: shape, shown: shown))
    }
}

private struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    let shown: Bool
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        content.overlay(shape.strokeBorder(tint, lineWidth: Stroke.focus).padding(-Stroke.focus - 1).opacity(shown ? 1 : 0))
    }
}
