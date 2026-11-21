import AppKit
import ImpKit
import SwiftUI
import ImpDesign

/// The bubble's body: one fill in one continuous rounded shape. Solid, it is `Tone.raised` with one
/// soft shadow. Translucent (a Mac setting, see `BubbleAppearance`), it is the same `Tone.raised` at the
/// chosen opacity over a blur of what is behind the bubble, with a hairline edge instead of the shadow
/// (a shadow would show through the fill). Only the fill is translucent: the content on top never is.
/// The system's Reduce Transparency and Increase Contrast make it solid.
struct BubbleSurface: View {
    var cornerRadius: CGFloat = Radius.bubble
    /// No blur at all (the Settings preview, which is not in a panel over the desktop).
    var blursWindowContent = false

    var body: some View { BubbleFill(cornerRadius: cornerRadius, blursWindowContent: blursWindowContent) }
}

/// The fill of the bubble and of each pebble of its trail, so they are one surface.
struct BubbleFill: View {
    let cornerRadius: CGFloat
    var blursWindowContent = false
    var shadow: (radius: CGFloat, y: CGFloat) = (Spacing.small, Spacing.tight)
    @Environment(\.bubbleAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var opacity: Double {
        appearance.fillOpacity(reduceTransparency: reduceTransparency, increaseContrast: contrast == .increased)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if opacity >= 1 {
            // Reaches about 2 x radius + offset (20 pt) from the shape: inside `BubbleView.margin`.
            shape.fill(Tone.raised).shadow(color: Elevation.cardColor, radius: shadow.radius, y: shadow.y)
        } else {
            ZStack {
                if !blursWindowContent { BubbleBlur(cornerRadius: cornerRadius) }
                shape.fill(Tone.raised.opacity(opacity))
                BubbleEdge(cornerRadius: cornerRadius).fill(Tone.line, style: FillStyle(eoFill: true))
            }
            .clipShape(shape)
        }
    }
}

/// A hairline ring just inside the shape, so a translucent bubble reads on a background of its own colour.
struct BubbleEdge: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
        let inner = rect.insetBy(dx: Stroke.hairline, dy: Stroke.hairline)
        path.addRoundedRect(in: inner, cornerSize: CGSize(width: max(cornerRadius - Stroke.hairline, 0), height: max(cornerRadius - Stroke.hairline, 0)), style: .continuous)
        return path
    }
}

private struct BubbleAppearanceKey: EnvironmentKey {
    static let defaultValue = BubbleAppearance()
}

extension EnvironmentValues {
    /// How the bubble is filled (set by `BubbleView` from the preferences).
    var bubbleAppearance: BubbleAppearance {
        get { self[BubbleAppearanceKey.self] }
        set { self[BubbleAppearanceKey.self] = newValue }
    }
}

/// Two little pebbles trailing from the card toward Imp.
struct Trail: View {
    let offset: CGFloat
    let width: CGFloat

    var body: some View {
        let limit = width / 2 - 30
        let x = min(max(offset, -limit), limit)
        let drift: CGFloat = offset == x ? 0 : (offset > 0 ? 4 : -4)   // lean toward Imp when clamped
        ZStack(alignment: .topLeading) {
            pebble(BubbleMetrics.trailBig).offset(x: width / 2 + x - BubbleMetrics.trailBig / 2)
            pebble(BubbleMetrics.trailSmall).offset(x: width / 2 + x - BubbleMetrics.trailSmall / 2 + drift, y: BubbleMetrics.trailBig + Spacing.hairline)
        }
        .frame(width: width, height: BubbleMetrics.trailHeight, alignment: .topLeading)
    }

    private func pebble(_ side: CGFloat) -> some View {
        BubbleFill(cornerRadius: side / 2, shadow: (Spacing.tight, Spacing.hairline))
            .frame(width: side, height: side)
    }
}

/// The scrolling text of a reply read in full, with a classic scroll bar that stays visible
/// while the text overflows (the system's overlay bars hide until you scroll) and hides when
/// it all fits. You can drag it, like any scroll bar.
struct ReadingScroll<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.background(PersistentScroller())
        }
        .frame(height: height)
    }
}

/// Finds the scroll view it lives in and gives it a classic, always-visible scroll bar.
struct PersistentScroller: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let v = view, !(v is NSScrollView) { view = v.superview }
            guard let scroll = view as? NSScrollView, !(scroll.verticalScroller is TracklessScroller) else { return }
            let scroller = TracklessScroller()
            scroller.scrollerStyle = .legacy
            scroller.knobStyle = .default
            scroll.hasVerticalScroller = true
            scroll.verticalScroller = scroller
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = true            // only while the text overflows
            scroll.drawsBackground = false
            scroll.tile()
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The native knob (draggable as usual) without the opaque track, so it sits nicely on the bubble.
    final class TracklessScroller: NSScroller {
        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Resize grips on the bubble: a thin strip along each edge, and a square at each corner that
/// resizes both ways. (On the bubble, not its transparent margin, so they catch the mouse.)
struct ResizeHandles: View {
    let resize: (Edge.Set, Bool) -> Void
    private static let thickness: CGFloat = 6, corner: CGFloat = 16

    var body: some View {
        ZStack {
            strip([.top], .top)
            strip([.bottom], .bottom)
            strip([.leading], .leading)
            strip([.trailing], .trailing)
            grip([.top, .leading], .topLeading)
            grip([.top, .trailing], .topTrailing)
            grip([.bottom, .leading], .bottomLeading)
            grip([.bottom, .trailing], .bottomTrailing)
        }
    }

    private func strip(_ edges: Edge.Set, _ alignment: Alignment) -> some View {
        let horizontal = edges.contains(.top) || edges.contains(.bottom)
        return handle(edges)
            .frame(width: horizontal ? nil : Self.thickness, height: horizontal ? Self.thickness : nil)
            .padding(horizontal ? .horizontal : .vertical, Self.corner)      // the corners have their own grips
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func grip(_ edges: Edge.Set, _ alignment: Alignment) -> some View {
        handle(edges)
            .frame(width: Self.corner, height: Self.corner)
            .padding(Spacing.tight)                                                     // stay on the rounded corner
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func handle(_ edges: Edge.Set) -> some View {
        Color.clear                                        // hit-testable, invisible: it paints nothing
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: Self.position(of: edges)))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in resize(edges, false) }
                .onEnded { _ in resize(edges, true) })
    }

    /// The resize cursor for a handle: the arrows of the edge or corner it sits on.
    private static func position(of edges: Edge.Set) -> FrameResizePosition {
        let top = edges.contains(.top), bottom = edges.contains(.bottom)
        let leading = edges.contains(.leading), trailing = edges.contains(.trailing)
        if top && leading { return .topLeading }
        if top && trailing { return .topTrailing }
        if bottom && leading { return .bottomLeading }
        if bottom && trailing { return .bottomTrailing }
        if top { return .top }
        if bottom { return .bottom }
        if leading { return .leading }
        return .trailing
    }
}

/// The chat's visible resize mark in its bottom corner (the edges and corners all resize too).
/// It only decorates: the drag handles sit over it.
struct ResizeGrip: View {
    var body: some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(Typeface.small.weight(.semibold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(Tone.muted)
            .opacity(0.4)                                  // a quiet mark: it shows where to resize, nothing more
            .frame(width: BubbleMetrics.grip, height: BubbleMetrics.grip)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A small floating ✕ just outside the card's corner. The whole circle is the target.
struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        CornerButton(icon: "xmark", weight: .heavy, help: "Close (and stop whatever I'm doing)", action: action)
    }
}

/// Copies the answer from the card's bottom corner, ✓ for a moment once done.
struct CopyCornerButton: View {
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        CornerButton(icon: copied ? "checkmark" : "doc.on.doc", weight: .bold, help: "Copy the answer") {
            action()
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
    }
}

/// A small round button floating on one of the card's corners (✕ at the top, copy at the bottom).
struct CornerButton: View {
    let icon: String
    var weight = Font.Weight.heavy
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.icon(.tiny, weight: weight))
                .foregroundStyle(hover ? Tone.text : Tone.muted)
                .frame(width: BubbleMetrics.corner, height: BubbleMetrics.corner)
                .background {
                    Circle().fill(hover ? Tone.raisedHigh : Tone.raised)
                        .shadow(color: Elevation.cardColor, radius: Spacing.tight, y: Spacing.hairline)
                }
                .contentShape(Circle())
                .scaleEffect(hover ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Round icon button used along the bubble's bottom edge.
struct IconButton: View {
    @Environment(\.impTint) private var tint
    let icon: String
    let help: LocalizedStringKey
    var active = false
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.icon(.medium))
                .foregroundStyle(active ? AnyShapeStyle(LegibleTint(on: .raised)) : AnyShapeStyle(hover ? Tone.text : Tone.muted))
                .frame(width: size, height: size)
                .background(Circle().fill(hover ? Tone.cardHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Copy

struct CopyButton: View {
    var size: CGFloat = 26
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        IconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy", active: copied, size: size) {
            action()
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        }
    }
}
