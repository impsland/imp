import ImpDesign
import ImpKit
import SwiftUI

// The window's own building blocks: the title bar, settings pages and sheets. Cards,
// rows, fields, chips and buttons come from ImpDesign.

/// Sizes of the Mac window's own chrome, which only the Mac has. Everything else is an ImpDesign token.
enum Metrics {
    /// The title bar row (traffic lights are 14 pt tall, centred 16 pt from the top).
    static let barHeight: CGFloat = 32
    /// Room the traffic lights take on the left (they end at x = 69).
    static let trafficLights: CGFloat = 78
}

extension ControlInk {
    /// The stored choice as the design system's value, for `EnvironmentValues.tintInk`.
    var tintInk: TintInk {
        switch self {
        case .white: .white
        case .black: .black
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .white: "settings.app.control_ink.white"
        case .black: "settings.app.control_ink.black"
        }
    }

    /// A letter on a filled disc for white, on an empty one for black.
    var symbol: String {
        switch self {
        case .white: "a.circle.fill"
        case .black: "a.circle"
        }
    }
}

/// A settings page: a centred column of cards that scrolls.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) { content }
                    .padding(.horizontal, Spacing.page)
                    .padding(.top, Spacing.hairline)
                    .padding(.bottom, Spacing.page)
                    .frame(maxWidth: Sizing.column)
                    .frame(maxWidth: .infinity)
                    .scrollsToHighlightedSetting(proxy)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.automatic)
            .impControls()
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
        // The title is centred on the window. The back button and the trailing actions keep their own
        // room on each side, so a long title ends in "…" instead of running under them.
        HStack(spacing: Spacing.small) {
            HStack(spacing: Spacing.small) {
                if let back {
                    Button(action: back) { HoverGlyph(systemName: "chevron.left", tint: Tone.text) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help(backHelp)
                        .accessibilityLabel(Text("common.back"))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            center.layoutPriority(1)
            HStack(spacing: Spacing.small) {
                Spacer(minLength: 0)
                trailing
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.leading, Metrics.trafficLights)
        .padding(.trailing, Spacing.medium)
        .frame(height: Metrics.barHeight)
    }
}

extension TopBar where Trailing == EmptyView {
    init(back: (() -> Void)? = nil, backHelp: LocalizedStringKey = "Back to the Imps (Esc)", @ViewBuilder center: () -> Center) {
        self.init(back: back, backHelp: backHelp, center: center, trailing: { EmptyView() })
    }
}

// MARK: - Sheets

/// The shell of every sheet: the app's flat surface behind, a header on top, a body that scrolls, and a
/// footer of buttons that stays put.
///
/// A sheet can't be taller than the window it hangs from, and macOS cuts off whatever doesn't fit
/// (the buttons, first). So the body sits in a scroll view sized to fit it, and no taller than the
/// window leaves room for: as it grows (a prompt box appearing, conditions added) the sheet grows
/// with it, then scrolls, and the header and the buttons always stay in view.
struct SheetFrame<Header: View, Content: View, Footer: View>: View {
    var width: CGFloat = Sizing.sheetWidth
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
                VStack(alignment: .leading, spacing: Spacing.roomy) { content }
                    .padding(.horizontal, Spacing.page)
                    .padding(.vertical, Spacing.roomy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: bodyHeight)
            HStack(spacing: Spacing.small) { footer }
                .padding(.horizontal, Spacing.page)
                .padding(.vertical, Spacing.medium)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(width: width)
        .background { Backdrop() }
        // The sheet's own window is the same surface, so no system background shows at its edge.
        .presentationBackground(Tone.surface)
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
    var width: CGFloat = Sizing.sheetWidth
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    @Environment(\.impTint) private var tint
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(width: width) {
            HStack(spacing: Spacing.cozy) {
                IconTile(systemName: icon, filled: true, side: Sizing.sheetIcon)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(Typeface.title).foregroundStyle(Tone.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let info { InfoTip(info) }
                Spacer(minLength: Spacing.small)
                accessory
                // The one way to close a sheet: a close button in the corner (Escape works too).
                HoverIconButton(systemName: "xmark", help: "common.close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.page)
            .padding(.top, Spacing.page)
            .padding(.bottom, Spacing.hairline)
        } content: {
            content
        } footer: {
            footer
        }
    }
}

extension SheetScaffold where Accessory == EmptyView {
    init(icon: String, title: LocalizedStringKey, info: LocalizedStringKey? = nil, width: CGFloat = Sizing.sheetWidth,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(icon: icon, title: title, info: info, width: width, accessory: { EmptyView() }, content: content, footer: footer)
    }
}

/// How tall a sheet may be: the app's window, less a margin so the sheet clearly hangs inside it.
@MainActor
enum SheetRoom {
    static let margin: CGFloat = Spacing.wide
    /// Never squeeze a form below this (a tiny window scrolls a little more instead).
    static let minimumForm: CGFloat = Sizing.control * 4

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
    var color: Color = Tone.warnText
    /// Pops the explanation open on its own when it appears (or its text changes).
    var opensItself = true
    private let textID: String

    init(text: LocalizedStringKey, symbol: String = "exclamationmark.triangle.fill", color: Color = Tone.warnText, opensItself: Bool = true) {
        self.text = Text(text); self.textID = String(describing: text)
        self.symbol = symbol; self.color = color; self.opensItself = opensItself
    }

    /// For text that's already been localized or is data.
    init(verbatim text: String, symbol: String = "exclamationmark.triangle.fill", color: Color = Tone.warnText, opensItself: Bool = true) {
        self.text = Text(verbatim: text); self.textID = text
        self.symbol = symbol; self.color = color; self.opensItself = opensItself
    }
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: symbol)
                .font(.icon(.large))
                .foregroundStyle(color)
                .frame(minWidth: Sizing.hit, minHeight: Sizing.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .impPopover(isPresented: $showing) {
            text
                .font(Typeface.caption)
                .frame(maxWidth: Sizing.tipWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.medium)
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

