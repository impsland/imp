import ImpDesign
import SwiftUI
import UIKit

/// What's wrong (or worth knowing) about something, kept out of the way: a small icon next to it,
/// whose words show in a tooltip when you tap it. The app never spells problems out inline.
///
/// The tooltip is drawn by the screen (`tipHost()`), not by the system popover: one shape with one
/// corner radius from the design system, and its arrow part of that same shape. Rows of a list clip
/// what sticks out of them, so the tooltip sits above the whole screen instead.
struct IssueBadge: View {
    enum Kind {
        /// Something to fix before it works.
        case problem
        /// A tip: nothing's wrong.
        case info
    }

    var text: String
    var kind: Kind = .problem
    /// Opens the tooltip as soon as it appears (for a problem you just caused, like a bad paste).
    var opensAtOnce = false
    @Environment(\.tipCenter) private var center
    @State private var frame = CGRect.zero
    @State private var id = UUID()

    var body: some View {
        Button { center?.toggle(id: id, text: text, anchor: frame) } label: {
            Image(systemName: kind == .problem ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(kind == .problem ? Dungeon.flame : Dungeon.muted)
                .symbolEffect(.bounce, value: text)
                .frame(width: Sizing.hit, height: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The icon is small, the target is not. Neighbours keep their distance from the icon itself.
        .padding(.horizontal, -7).padding(.vertical, -7)
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: BadgeFrame.self, value: geo.frame(in: .global))
            }
        }
        .onPreferenceChange(BadgeFrame.self) { frame = $0 }
        .accessibilityLabel(text)
        .task(id: text) {
            // A tooltip that is open follows the words, and one that asked to open does so.
            if center?.tip?.id == id { center?.show(id: id, text: text, anchor: frame) }
            guard opensAtOnce else { return }
            try? await Task.sleep(for: .milliseconds(250))
            center?.show(id: id, text: text, anchor: frame)
        }
        .onDisappear { center?.hide(id: id) }
        .transition(.scale.combined(with: .opacity))
    }
}

private struct BadgeFrame: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - The tooltip

/// The tooltip a screen is showing, if any. One at a time.
@MainActor @Observable
final class TipCenter {
    struct Tip: Equatable {
        var id: UUID
        var text: String
        /// The icon it points at, in window coordinates.
        var anchor: CGRect
    }

    private(set) var tip: Tip?
    @ObservationIgnored private var closing: Task<Void, Never>?

    func show(id: UUID, text: String, anchor: CGRect) {
        guard anchor != .zero else { return }
        tip = Tip(id: id, text: text, anchor: anchor)
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { tip = nil }
        }
    }

    func toggle(id: UUID, text: String, anchor: CGRect) {
        if tip?.id == id { hide(id: id) } else { show(id: id, text: text, anchor: anchor) }
    }

    func hide(id: UUID) {
        guard tip?.id == id else { return }
        close()
    }

    func close() {
        closing?.cancel()
        tip = nil
    }
}

extension EnvironmentValues {
    @Entry var tipCenter: TipCenter?
}

extension View {
    /// Lets the `IssueBadge`s inside show their tooltips over this view. Put it on the root of every
    /// screen and sheet that has badges (a sheet is a screen of its own).
    func tipHost() -> some View { modifier(TipHost()) }
}

private struct TipHost: ViewModifier {
    @State private var center = TipCenter()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.tipCenter, center)
            .overlay {
                GeometryReader { geo in
                    if let tip = center.tip {
                        let origin = geo.frame(in: .global).origin
                        ZStack(alignment: .topLeading) {
                            // A tap anywhere else puts it away.
                            Color.clear.contentShape(Rectangle()).onTapGesture { center.close() }
                            TipBubble(text: tip.text, anchor: tip.anchor.offsetBy(dx: -origin.x, dy: -origin.y), container: geo.size)
                        }
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : Timing.smooth, value: center.tip)
            }
    }
}

/// The words in their bubble, above the icon, or below it when there is no room above.
private struct TipBubble: View {
    let text: String
    let anchor: CGRect
    let container: CGSize

    private static let arrow: CGFloat = 8
    private static let margin: CGFloat = 16

    var body: some View {
        let width = min(260, container.width - 2 * Self.margin)
        let left = min(max(anchor.midX - width / 2, Self.margin), max(container.width - Self.margin - width, Self.margin))
        let above = anchor.minY > 140
        let edge = above ? anchor.minY - 4 : anchor.maxY + 4
        Text(text)
            .font(Typeface.caption)
            .foregroundStyle(Dungeon.cream)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width - 28, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .padding(above ? .bottom : .top, Self.arrow)
            .background {
                TipShape(arrowX: anchor.midX - left, above: above, radius: Radius.medium, arrow: Self.arrow)
                    .fill(Dungeon.wallBottom)
                    .overlay(TipShape(arrowX: anchor.midX - left, above: above, radius: Radius.medium, arrow: Self.arrow)
                        .stroke(Dungeon.stoneLight.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            // The icon already says the same words to VoiceOver.
            .accessibilityHidden(true)
            .alignmentGuide(.leading) { _ in -left }
            .alignmentGuide(.top) { d in above ? d.height - edge : -edge }
    }
}

/// A rounded rectangle with a small arrow on its bottom edge (or its top edge), all one outline.
private struct TipShape: Shape {
    /// Where the arrow's tip is along the width.
    var arrowX: CGFloat
    /// Arrow below the box (the tooltip is above its icon), else above it.
    var above: Bool
    var radius: CGFloat
    var arrow: CGFloat

    func path(in rect: CGRect) -> Path {
        let half = arrow
        let tip = min(max(arrowX, radius + half), rect.width - radius - half)
        let body = CGRect(x: 0, y: 0, width: rect.width, height: rect.height - arrow)
        let r = radius
        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addRelativeArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r, startAngle: .degrees(-90), delta: .degrees(90))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addRelativeArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r, startAngle: .degrees(0), delta: .degrees(90))
        p.addLine(to: CGPoint(x: tip + half, y: body.maxY))
        p.addLine(to: CGPoint(x: tip, y: body.maxY + arrow))
        p.addLine(to: CGPoint(x: tip - half, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addRelativeArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r, startAngle: .degrees(90), delta: .degrees(90))
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addRelativeArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r, startAngle: .degrees(180), delta: .degrees(90))
        p.closeSubpath()
        if above { return p }
        return p.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height))
    }
}
