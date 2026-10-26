import AppKit
import ImpKit
import SwiftUI

/// Frosted, semi-transparent card: the desktop blurs through, with a faint Imp-red glow on top.
struct Glass: View {
    var cornerRadius: CGFloat
    var tint: Color = .imp
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        VisualEffect()
            .clipShape(shape)
            .overlay(shape.fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.14 : 0.045), .clear],
                                               startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.18 : 0.6), .white.opacity(0.05)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .overlay(shape.strokeBorder(Color.black.opacity(scheme == .dark ? 0.5 : 0.08), lineWidth: 0.5).padding(-0.5))
            // A soft ambient shadow (reaches ~22 pt below, ~13 above: inside the margin) and a
            // crisp contact shadow, instead of one big one the panel's edge would cut.
            .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 8.5, y: 5)
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 1.2, y: 0.5)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Two little glass dots trailing from the card toward Imp.
struct Trail: View {
    let offset: CGFloat
    let width: CGFloat

    var body: some View {
        let limit = width / 2 - 30
        let x = min(max(offset, -limit), limit)
        let drift: CGFloat = offset == x ? 0 : (offset > 0 ? 4 : -4)   // lean toward Imp when clamped
        ZStack(alignment: .topLeading) {
            Glass(cornerRadius: 5).frame(width: 10, height: 10).offset(x: width / 2 + x - 5)
            Glass(cornerRadius: 3).frame(width: 6, height: 6).offset(x: width / 2 + x - 3 + drift, y: 12)
        }
        .frame(width: width, height: 19, alignment: .topLeading)
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

    /// The native knob (draggable as usual) without the opaque track, so it sits nicely on glass.
    final class TracklessScroller: NSScroller {
        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Resize grips on the glass: a thin strip along each edge, and a square at each corner that
/// resizes both ways. (On the glass, not its transparent margin, so they catch the mouse.)
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
            .padding(3)                                                     // stay on the rounded glass
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func handle(_ edges: Edge.Set) -> some View {
        Color.white.opacity(0.001)                                          // hit-testable, invisible
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in resize(edges, false) }
                .onEnded { _ in resize(edges, true) })
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

/// A small glass button floating on one of the card's corners (✕ at the top, copy at the bottom).
struct CornerButton: View {
    let icon: String
    var weight = Font.Weight.heavy
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: weight))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background { Glass(cornerRadius: 10) }
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
    let help: String
    var active = false
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(active ? tint : (hover ? .primary : .secondary))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Phases

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
