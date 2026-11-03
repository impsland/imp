import ImpDesign
import ImpKit
import SwiftUI

// The window's own building blocks: the title bar, settings pages, the even grid and sheets. Cards,
// rows, fields, chips and buttons come from ImpDesign.

/// Sizes of the Mac window's own furniture. Corners, gaps and control sizes are ImpDesign tokens.
enum Metrics {
    /// The title bar row (traffic lights are 14 pt tall, centred 16 pt from the top).
    static let barHeight: CGFloat = 32
    /// Room the traffic lights take on the left (they end at x = 69).
    static let trafficLights: CGFloat = 78
    /// The widest a settings column grows; wider windows centre it.
    static let column: CGFloat = 720
}

/// A settings page: a centred column of cards that scrolls.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.medium) { content }
                .padding(.horizontal, Spacing.page)
                .padding(.top, 2)
                .padding(.bottom, Spacing.page)
                .frame(maxWidth: Metrics.column)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
        .impControls()
    }
}

// MARK: - Grid

/// Lays children out in rows that always fill the full width. Rows are balanced (ten items that
/// need two rows go five and five, never nine and one), and a shorter row stretches its items so
/// no row ends in an empty slot. Items in a row share its height.
struct EvenGrid: Layout {
    var minWidth: CGFloat
    var maxColumns = Int.max
    var spacing: CGFloat = 8

    /// As wide as up to four columns at their narrowest: the size asked for when the width is open.
    private func naturalWidth(_ count: Int) -> CGFloat {
        (minWidth + spacing) * CGFloat(min(max(count, 1), 4)) - spacing
    }

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, width: CGFloat, height: CGFloat)] {
        // SwiftUI also asks "how big at an endless width?": that is the natural width, not a crash
        // turning infinity into a column count.
        let width = width.isFinite ? width : naturalWidth(subviews.count)
        let fit = min(max(1, Int((width + spacing) / (minWidth + spacing))), maxColumns)
        var out: [(Range<Int>, CGFloat, CGFloat)] = []
        var start = 0
        for length in RowBalance.lineLengths(count: subviews.count, fit: fit) {
            let end = start + length
            let n = CGFloat(length)
            let w = max(0, (width - spacing * (n - 1)) / n)
            let h = subviews[start..<end].map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }.max() ?? 0
            out.append((start..<end, w, h))
            start = end
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? naturalWidth(subviews.count)
        let r = rows(width, subviews)
        let height = r.map(\.height).reduce(0, +) + spacing * CGFloat(max(r.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.range {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: row.width, height: row.height))
                x += row.width + spacing
            }
            y += row.height + spacing
        }
    }
}

// MARK: - Navigation

/// The title bar row, level with the traffic lights: a back button beside them, a centred title
/// and an optional control on the right.
struct TopBar<Center: View, Trailing: View>: View {
    var back: (() -> Void)?
    var backHelp: LocalizedStringKey = "Back to the Imps (Esc)"
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            center.frame(maxWidth: 360)
            HStack(spacing: 8) {
                if let back {
                    Button(action: back) { RoundGlyph(systemName: "chevron.left", size: 26, bold: true) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help(backHelp)
                        .accessibilityLabel("Back")
                }
                Spacer()
                trailing
            }
        }
        .padding(.leading, Metrics.trafficLights)
        .padding(.trailing, 12)
        .frame(height: Metrics.barHeight)
    }
}

extension TopBar where Trailing == EmptyView {
    init(back: (() -> Void)? = nil, backHelp: LocalizedStringKey = "Back to the Imps (Esc)", @ViewBuilder center: () -> Center) {
        self.init(back: back, backHelp: backHelp, center: center, trailing: { EmptyView() })
    }
}

/// A `ChoiceChip` with a small ↗ at its end that opens `link` (where to get a key or a model):
/// the name picks, the arrow leads out.
struct LinkedChoiceChip: View {
    let title: String
    let picked: Bool
    let link: URL
    let linkHelp: String
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.openURL) private var openURL
    @State private var hover = false
    @State private var hoverLink = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.leading, 12).padding(.trailing, 4)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(picked ? .isSelected : [])
            Button { openURL(link) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(hoverLink ? (picked ? 0.28 : 0.16) : 0)))
                    .padding(.trailing, 6)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverLink = $0 }
            .help(linkHelp)
            .accessibilityLabel(linkHelp)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.9))
        .background(Capsule().fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.1 : 0.06))))
        .overlay(Capsule().strokeBorder(picked ? Color.white.opacity(0.2) : Dungeon.cardEdge))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .animation(.easeOut(duration: 0.12), value: hoverLink)
    }
}

// MARK: - Sheets

/// Sizes every sheet agrees on.
enum SheetMetrics {
    static let padding: CGFloat = 20
    static let gap: CGFloat = 14
    static let width: CGFloat = 520
    static let footerPadding: CGFloat = 12
    static let iconTile: CGFloat = 32
}

/// The shell of every sheet: the dungeon wall behind, a header on top, a body that scrolls, and a
/// footer of buttons that stays put.
///
/// A sheet can't be taller than the window it hangs from, and macOS cuts off whatever doesn't fit
/// (the buttons, first). So the body sits in a scroll view sized to fit it, and no taller than the
/// window leaves room for: as it grows (a prompt box appearing, conditions added) the sheet grows
/// with it, then scrolls, and the header and the buttons always stay in view.
struct SheetFrame<Header: View, Content: View, Footer: View>: View {
    var width: CGFloat = SheetMetrics.width
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.sheetRoom) private var fixedRoom
    @State private var windowRoom = SheetRoom.available()
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SheetMetrics.gap) { content }
                    .padding(.horizontal, SheetMetrics.padding)
                    .padding(.vertical, SheetMetrics.gap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: bodyHeight)
            HStack(spacing: 8) { footer }
                .padding(.horizontal, SheetMetrics.padding)
                .padding(.vertical, SheetMetrics.footerPadding)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.18))
                .overlay(alignment: .top) { CardDivider() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: width)
        .background(Dungeon.wall)
        .environment(\.colorScheme, .dark)
        .impControls()
        .focusSection()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            guard let window = note.object as? NSWindow, window === HomeWindow.shared.window else { return }
            windowRoom = SheetRoom.available()
        }
    }

    /// The body's own height, or what's left of the window once the header and buttons are in.
    private var bodyHeight: CGFloat? {
        guard contentHeight > 0 else { return nil }
        let room = max((fixedRoom ?? windowRoom) - headerHeight - footerHeight, SheetRoom.minimumForm)
        return min(contentHeight.rounded(.up), room)
    }
}

/// The usual sheet: a header (icon, title, ⓘ, an optional control), the form, and a footer of buttons.
struct SheetScaffold<Content: View, Accessory: View, Footer: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    var width: CGFloat = SheetMetrics.width
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.impTint) private var tint

    var body: some View {
        SheetFrame(width: width) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: SheetMetrics.iconTile, height: SheetMetrics.iconTile)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let info { InfoTip(info) }
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, SheetMetrics.padding)
            .padding(.top, SheetMetrics.padding)
            .padding(.bottom, 2)
        } content: {
            content
        } footer: {
            footer
        }
    }
}

extension SheetScaffold where Accessory == EmptyView {
    init(icon: String, title: LocalizedStringKey, info: LocalizedStringKey? = nil, width: CGFloat = SheetMetrics.width,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(icon: icon, title: title, info: info, width: width, accessory: { EmptyView() }, content: content, footer: footer)
    }
}

/// Cancel, the way every sheet has it: Esc works too.
struct SheetCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button("Cancel", role: .cancel, action: action).buttonStyle(.quiet).keyboardShortcut(.cancelAction)
    }
}

/// How tall a sheet may be: the app's window, less a margin so the sheet clearly hangs inside it.
@MainActor
enum SheetRoom {
    static let margin: CGFloat = 24
    /// Never squeeze a form below this (a tiny window scrolls a little more instead).
    static let minimumForm: CGFloat = 140

    static func available() -> CGFloat {
        if let window = HomeWindow.shared.window { return window.contentLayoutRect.height - margin }
        return (NSScreen.main?.visibleFrame.height ?? 800) * 0.8
    }
}

extension EnvironmentValues {
    /// A fixed height for sheets (offscreen design renders, which have no app window to measure).
    @Entry var sheetRoom: CGFloat? = nil
}


// MARK: - Compact controls

/// A problem, in as little room as possible: a coloured icon whose explanation pops up by itself
/// the moment it appears (so it's seen right away), and again on a click.
struct IssueTip: View {
    let text: Text
    var symbol = "exclamationmark.triangle.fill"
    var color: Color = .orange
    /// Pops the explanation open on its own when it appears (or its text changes).
    var opensItself = true
    private let textID: String

    init(text: LocalizedStringKey, symbol: String = "exclamationmark.triangle.fill", color: Color = .orange, opensItself: Bool = true) {
        self.text = Text(text); self.textID = String(describing: text)
        self.symbol = symbol; self.color = color; self.opensItself = opensItself
    }

    /// For text that's already been localized or is data.
    init(verbatim text: String, symbol: String = "exclamationmark.triangle.fill", color: Color = .orange, opensItself: Bool = true) {
        self.text = Text(verbatim: text); self.textID = text
        self.symbol = symbol; self.color = color; self.opensItself = opensItself
    }
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            text
                .font(.system(size: 12))
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .task(id: textID) {
            guard opensItself else { return }
            try? await Task.sleep(for: .milliseconds(300))     // let the sheet or row settle first
            showing = true
        }
        .help(text)
        .accessibilityLabel(text)
    }
}

