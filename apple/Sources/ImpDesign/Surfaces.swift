import SwiftUI

// Popovers and help tips. A popover's body and its arrow are drawn by the system as one piece, in the
// system's popover material, on the Mac and on the iPhone, in light and in dark. The app does not
// paint a background of its own under a popover: `presentationBackground` colours the body but not
// the arrow (the Mac's arrow belongs to the popover's frame, which has no colour to set), and that
// left a seam where the two met. What the app adds is its text colour, its controls and the Imp's tint.

private struct PopoverSurface: ViewModifier {
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Tone.text)
            .impControls(tint: tint)
            // A phone keeps it a small popover beside what was tapped instead of turning it into a sheet.
            .presentationCompactAdaptation(.popover)
    }
}

extension View {
    /// Gives popover content the app's text colour, controls and the Imp's tint. The background, body
    /// and arrow alike, is the system's. Use it on the content inside `.popover`. `.impPopover` does
    /// it for you.
    public func impPopoverSurface() -> some View {
        modifier(PopoverSurface())
    }

    /// A popover with the app's controls. On the iPhone it stays a popover rather than a sheet.
    public func impPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(ImpPopover(isPresented: isPresented, arrowEdge: arrowEdge, content: content))
    }
}

/// SwiftUI emits `popover(…arrowEdge:)` into the module that calls it, and exports no symbol for its
/// result type. A private modifier keeps that call, and its result type, inside this module, so
/// optimised builds of the apps never inline it and look for a symbol SwiftUI does not export.
private struct ImpPopover<PopoverContent: View>: ViewModifier {
    let isPresented: Binding<Bool>
    let arrowEdge: Edge
    let content: () -> PopoverContent

    func body(content anchor: Content) -> some View {
        anchor.popover(isPresented: isPresented, arrowEdge: arrowEdge) { content().impPopoverSurface() }
    }
}

/// The header and footer lines of a popover that holds a list: a title on the leading edge and a
/// quiet detail (a count, a status) on the trailing edge, on the same grid as the rows below.
public struct PopoverHeader<Trailing: View>: View {
    let title: Text
    let trailing: Trailing

    public init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.trailing = trailing()
    }

    public init(verbatim title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(verbatim: title)
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: Spacing.small) {
            title.font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.small)
            trailing.font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
        }
        .frame(minHeight: Sizing.hit)
    }
}

extension PopoverHeader where Trailing == EmptyView {
    public init(_ title: LocalizedStringKey) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - Help

/// Gives its content the content's own width up to `max`, and lets it wrap beyond that. The
/// result never stretches to the width on offer.
struct FitWidth: Layout {
    let max: CGFloat

    private func size(_ child: LayoutSubview) -> CGSize {
        let natural = child.sizeThatFits(.unspecified)
        guard natural.width > max else { return natural }
        return child.sizeThatFits(ProposedViewSize(width: max, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first.map(size) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(at: bounds.origin, proposal: ProposedViewSize(size(child)))
    }
}

/// The one way to explain something: a small help icon. A click or a tap opens the explanation as a
/// small popover whose arrow points at the icon itself. It is the only
/// help mechanism: there is no tooltip on hover, so nothing system-styled shows over the popover.
/// Screens never show the explanation as a paragraph of their own.
public struct InfoTip: View {
    let text: Text
    var symbol: String
    @State private var shown = false

    /// A literal is looked up in the String Catalog. Use `verbatim:` for a string that is shown as it is.
    public init(_ text: LocalizedStringKey, symbol: String = "questionmark.circle") {
        self.text = Text(text)
        self.symbol = symbol
    }

    public init(verbatim text: String, symbol: String = "questionmark.circle") {
        self.text = Text(verbatim: text)
        self.symbol = symbol
    }

    public var body: some View {
        Button { shown.toggle() } label: {
            // The popover hangs from the glyph, not from the larger target around it, so its arrow
            // points at the icon it explains.
            Image(systemName: symbol)
                .font(.icon(.medium, weight: .medium))
                .impPopover(isPresented: $shown) {
                    // As wide as its words, up to the tip width, then it wraps: a short tip is a small tip.
                    FitWidth(max: Sizing.tipWidth) {
                        text
                            .font(Typeface.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(Spacing.medium)
                }
                .frame(minWidth: Sizing.hit, minHeight: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(TipStyle(open: shown))
        .accessibilityLabel(Text("common.help"))
        .accessibilityValue(text)
    }

    /// Quiet until it is pointed at or open.
    private struct TipStyle: ButtonStyle {
        let open: Bool

        func makeBody(configuration: Configuration) -> some View {
            Glyph(configuration: configuration, open: open)
        }

        private struct Glyph: View {
            let configuration: Configuration
            let open: Bool
            @State private var hover = false

            var body: some View {
                configuration.label
                    .foregroundStyle(hover || open || configuration.isPressed ? Tone.text : Tone.faint)
                    .onHover { hover = $0 }
                    .impAnimation(Motion.hover, value: hover)
            }
        }
    }
}
