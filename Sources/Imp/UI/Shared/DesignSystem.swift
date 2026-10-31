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
    let text: Text
    var symbol = "info.circle"
    @State private var hover = false
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    /// A literal is looked up in the String Catalog; use `verbatim:` for a string that is shown as it is.
    init(_ text: LocalizedStringKey, symbol: String = "info.circle") {
        self.text = Text(text)
        self.symbol = symbol
    }

    init(verbatim text: String, symbol: String = "info.circle") {
        self.text = Text(verbatim: text)
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
                text
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
    var title: LocalizedStringKey?
    var icon: String?
    var info: LocalizedStringKey?
    var accessory: Accessory
    var content: Content
    @Environment(\.impTint) private var tint

    init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil,
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
    init(_ title: LocalizedStringKey? = nil, icon: String? = nil, info: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// A labelled row: title (and ⓘ) on the left, its control on the right.
struct Row<Control: View>: View {
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, info: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
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
    let label: LocalizedStringKey
    var info: LocalizedStringKey?
    var width: CGFloat = 76
    @ViewBuilder var control: Control

    init(_ label: LocalizedStringKey, info: LocalizedStringKey? = nil, width: CGFloat = 76, @ViewBuilder control: () -> Control) {
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
    var placeholder: LocalizedStringKey?
    /// A placeholder that is code or a format, shown as it is.
    var codePlaceholder = ""
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
                    (placeholder.map { Text($0) } ?? Text(verbatim: codePlaceholder))
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
    let title: Text
    var icon: String?
    let picked: Bool
    let action: () -> Void

    init(title: LocalizedStringKey, icon: String? = nil, picked: Bool, action: @escaping () -> Void) {
        self.title = Text(title); self.icon = icon; self.picked = picked; self.action = action
    }

    /// For names and other text that's data, not interface.
    init(verbatim title: String, icon: String? = nil, picked: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: title); self.icon = icon; self.picked = picked; self.action = action
    }
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                title.font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
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

/// A status line in the window's voice: a coloured dot or symbol and a few words.
struct StatusText: View {
    let text: Text
    var symbol: String?
    var color: Color = Dungeon.muted

    init(text: LocalizedStringKey, symbol: String? = nil, color: Color = Dungeon.muted) {
        self.text = Text(text); self.symbol = symbol; self.color = color
    }

    /// For text that's already been localized or is data (an error from a server, say).
    init(verbatim text: String, symbol: String? = nil, color: Color = Dungeon.muted) {
        self.text = Text(verbatim: text); self.symbol = symbol; self.color = color
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
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

/// A round tick: filled in the colour when on.
struct SelectMark: View {
    let isOn: Bool
    var tint: Color

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(isOn ? Color.white : Color.clear)
            .frame(width: 20, height: 20)
            .background(Circle().fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.black.opacity(0.24))))
            .overlay(Circle().strokeBorder(isOn ? Color.white.opacity(0.25) : Dungeon.muted.opacity(0.7), lineWidth: 1.2))
    }
}

/// A card you tick as a whole: the mark on the left, the content dimmed while it's left out.
struct SelectableCard<Content: View>: View {
    @Binding var isOn: Bool
    var tint: Color?
    @ViewBuilder var content: Content
    @Environment(\.impTint) private var inherited
    @State private var hover = false

    private var color: Color { tint ?? inherited }

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } } label: {
            HStack(alignment: .top, spacing: 12) {
                SelectMark(isOn: isOn, tint: color)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(isOn ? 1 : 0.55)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .fill(isOn ? AnyShapeStyle(color.opacity(0.12)) : AnyShapeStyle(Dungeon.card)))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(isOn ? color.opacity(0.65) : (hover ? Dungeon.muted.opacity(0.5) : Dungeon.cardEdge), lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small pill: a symbol and a few words, in a colour.
struct Badge: View {
    let text: Text
    let symbol: String
    var color: Color = Dungeon.muted

    init(_ text: LocalizedStringKey, symbol: String, color: Color = Dungeon.muted) {
        self.text = Text(text)
        self.symbol = symbol
        self.color = color
    }

    init(verbatim text: String, symbol: String, color: Color = Dungeon.muted) {
        self.text = Text(verbatim: text)
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            text.lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
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

/// A pop-up menu that keeps to its size: an icon and a title that's cut short with "…" rather
/// than pushing the form (or the whole sheet) wider.
struct CompactMenu<Content: View>: View {
    let title: Text
    var symbol: String?
    var maxWidth: CGFloat = 200
    @ViewBuilder var content: Content

    init(title: LocalizedStringKey, symbol: String? = nil, maxWidth: CGFloat = 200, @ViewBuilder content: () -> Content) {
        self.title = Text(title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }

    /// For names and text that's already been localized.
    init(verbatim title: String, symbol: String? = nil, maxWidth: CGFloat = 200, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title); self.symbol = symbol; self.maxWidth = maxWidth; self.content = content()
    }
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                }
                title
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
