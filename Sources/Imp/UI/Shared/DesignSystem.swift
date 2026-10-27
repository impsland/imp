import ImpKit
import SwiftUI

// The window's building blocks, shared by the stage, every settings page and every sheet:
// one top bar, one tab bar, one card, one row, one field look and one grid. Explanations live
// behind `InfoTip`s, so the pages stay short and the controls do the talking.

/// Sizes every screen agrees on.
enum Metrics {
    /// The title bar row (traffic lights are 14 pt tall, centred 16 pt from the top).
    static let barHeight: CGFloat = 32
    /// Room the traffic lights take on the left (they end at x = 69).
    static let trafficLights: CGFloat = 78
    /// The widest a settings column grows; wider windows centre it.
    static let column: CGFloat = 720
    static let pagePadding: CGFloat = 20
    static let gap: CGFloat = 12
    static let corner: CGFloat = 14
    static let control: CGFloat = 30
}

// MARK: - Info

/// A small ⓘ that shows its text while you hover it (or click it). Every explanation goes here
/// instead of under the control it explains.
struct InfoTip: View {
    let text: String
    var symbol = "info.circle"
    @State private var hover = false
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    init(_ text: String, symbol: String = "info.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hover || shown ? Dungeon.cream : Dungeon.muted.opacity(0.75))
            .frame(width: 18, height: 18)
            .contentShape(Circle())
            .onHover { inside in
                hover = inside
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(280))
                        if !Task.isCancelled { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(12)
            }
            .accessibilityElement()
            .accessibilityLabel("Info")
            .accessibilityValue(text)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Cards and rows

/// A stone tablet on the dungeon wall holding one group of settings: a one-line header (icon,
/// title, ⓘ, and an optional control on the right), then its content.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var icon: String?
    var info: String?
    var accessory: Accessory
    var content: Content
    @Environment(\.impTint) private var tint

    init(_ title: String? = nil, icon: String? = nil, info: String? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.info = info
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
                    }
                    Text(title).font(.system(size: 14, weight: .bold, design: .rounded)).lineLimit(1)
                    if let info { InfoTip(info) }
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(minHeight: 26)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String? = nil, icon: String? = nil, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// A labelled row: title (and ⓘ) on the left, its control on the right.
struct Row<Control: View>: View {
    let title: String
    var info: String?
    @ViewBuilder var control: Control

    init(_ title: String, info: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.info = info
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).lineLimit(1)
            if let info { InfoTip(info) }
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 28)
    }
}

/// A form row whose label sits in a fixed column, so a card's controls line up.
struct FieldRow<Control: View>: View {
    let label: String
    var info: String?
    var width: CGFloat = 76
    @ViewBuilder var control: Control

    init(_ label: String, info: String? = nil, width: CGFloat = 76, @ViewBuilder control: () -> Control) {
        self.label = label
        self.info = info
        self.width = width
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Dungeon.muted).lineLimit(1)
                if let info { InfoTip(info) }
            }
            .frame(width: width, alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A hairline between rows in a card.
struct CardDivider: View {
    var body: some View { Rectangle().fill(Dungeon.cardEdge).frame(height: 1) }
}

/// A settings page: a centred column of cards that scrolls.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) { content }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.top, 2)
                .padding(.bottom, Metrics.pagePadding)
                .frame(maxWidth: Metrics.column)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.automatic)
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

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, width: CGFloat, height: CGFloat)] {
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
        let width = proposal.width ?? (minWidth + spacing) * CGFloat(min(subviews.count, 4)) - spacing
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
    var backHelp = "Back to the Imps (Esc)"
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
    init(back: (() -> Void)? = nil, backHelp: String = "Back to the Imps (Esc)", @ViewBuilder center: () -> Center) {
        self.init(back: back, backHelp: backHelp, center: center, trailing: { EmptyView() })
    }
}

/// A segmented bar of tabs as wide as the page: icon and title side by side, the chosen one
/// lit in the Imp's colour, sliding from tab to tab.
struct SegmentedTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: KeyPath<Tab, String>
    let icon: KeyPath<Tab, String>
    var badge: (Tab) -> Bool = { _ in false }
    @Environment(\.impTint) private var tint
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = tab } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab[keyPath: icon]).font(.system(size: 12, weight: .semibold))
                        Text(tab[keyPath: title]).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                        if badge(tab) { Circle().fill(.orange).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(on ? Color.white : Dungeon.muted)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if on {
                            Capsule().fill(tint.gradient).matchedGeometryEffect(id: "pill", in: pill)
                                .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab[keyPath: title])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Dungeon.card))
        .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
    }
}

// MARK: - Fields

/// Text fields and editors in the window's style: a dark well with a soft edge that lights up
/// in the Imp's colour while you type.
private struct FieldChrome: ViewModifier {
    var mono = false
    var large = false
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: large ? 14 : 13))
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: large ? 34 : Metrics.control)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.24)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.85) : Dungeon.cardEdge, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A multi-line well, with a placeholder.
struct EditorWell: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var height: CGFloat = 90
    @FocusState private var focused: Bool
    @Environment(\.impTint) private var tint

    var body: some View {
        TextEditor(text: $text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 5).padding(.vertical, 7)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.24)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.85) : Dungeon.cardEdge, lineWidth: focused ? 1.5 : 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

extension View {
    /// Dresses a `TextField` or `SecureField` in the window's field look.
    func impField(mono: Bool = false, large: Bool = false) -> some View {
        modifier(FieldChrome(mono: mono, large: large))
    }
}

/// Chips you pick one of (ideas, templates, hints), in the window's style.
struct ChoiceChip: View {
    let title: String
    var icon: String?
    let picked: Bool
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(picked ? Color.white : Dungeon.cream.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(Capsule().fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.1 : 0.06))))
            .overlay(Capsule().strokeBorder(picked ? Color.white.opacity(0.2) : Dungeon.cardEdge))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A status line in the window's voice: a coloured dot or symbol and a few words.
struct StatusText: View {
    let text: String
    var symbol: String?
    var color: Color = Dungeon.muted

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
    }
}

// MARK: - Sheets

/// Every sheet in the window: the dungeon wall behind, a header (icon, title, ⓘ, an optional
/// control), the form, and a footer of buttons.
struct SheetScaffold<Content: View, Accessory: View, Footer: View>: View {
    let icon: String
    let title: String
    var info: String?
    var width: CGFloat = 520
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(Dungeon.cream).lineLimit(1)
                if let info { InfoTip(info) }
                Spacer(minLength: 8)
                accessory
            }
            content
            HStack(spacing: 8) { footer }
                .padding(.top, 2)
        }
        .padding(18)
        .frame(width: width)
        .background(Dungeon.wall)
        .environment(\.colorScheme, .dark)
    }
}

extension SheetScaffold where Accessory == EmptyView {
    init(icon: String, title: String, info: String? = nil, width: CGFloat = 520,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(icon: icon, title: title, info: info, width: width, accessory: { EmptyView() }, content: content, footer: footer)
    }
}

// MARK: - Compact controls

/// A problem, in as little room as possible: a coloured icon whose explanation pops up by itself
/// the moment it appears (so it's seen right away), and again on a click.
struct IssueTip: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var color: Color = .orange
    /// Pops the explanation open on its own when it appears (or its text changes).
    var opensItself = true
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
            Text(text)
                .font(.system(size: 12))
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .task(id: text) {
            guard opensItself else { return }
            try? await Task.sleep(for: .milliseconds(300))     // let the sheet or row settle first
            showing = true
        }
        .help(text)
        .accessibilityLabel(text)
    }
}

/// A pop-up menu that keeps to its size: an icon and a title that's cut short with "…" rather
/// than pushing the form (or the whole sheet) wider.
struct CompactMenu<Content: View>: View {
    let title: String
    var symbol: String?
    var maxWidth: CGFloat = 200
    @ViewBuilder var content: Content
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: maxWidth - 50, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Dungeon.muted)
            }
            .foregroundStyle(Dungeon.cream)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(hover ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(title)
    }
}
