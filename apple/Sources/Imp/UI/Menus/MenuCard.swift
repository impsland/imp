import AppKit
import ImpDesign
import SwiftUI

/// Every right-click menu of the app (an Imp on the desktop or in the window, several Imps picked
/// together, empty space in the window) is one card of buttons, never a list of text items:
///
/// - the main actions are big pebbles in a grid, an icon over a short word (`MenuGrid`),
/// - things to choose from (a Brain, a trigger, a device) are pills, two to a row (`MenuPills`),
/// - what can't be undone (Goodbye) is one wide button at the bottom, in the danger colour (`MenuDangerButton`).
///
/// The order is the same in every menu, on the Mac and on the iPhone: what you do with the Imp (talk, type, chat),
/// where it is and its settings, how it looks (size, colour), what applies right now (Stop, Copy last reply), its
/// triggers, where it can visit, sharing it, and last and apart, Goodbye. A row never has a hole: a short last
/// row of buttons or pills shares the whole width.
///
/// A button that acts closes the menu first and then acts, so a window it opens comes forward. A choice
/// that is only a setting (size, colour, Brain) applies at once and leaves the menu open.
@MainActor
final class CardMenu: NSObject, NSMenuDelegate {
    private var pending: (@MainActor @Sendable () -> Void)?
    private weak var menu: NSMenu?

    /// A menu that is this one card. Keep the `CardMenu` alive while the menu is open.
    func make<Card: View>(_ card: Card) -> NSMenu {
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
        menu.delegate = self
        let item = NSMenuItem()
        // The menu adds its own band above and below a custom row (none at the sides): the card gives that much
        // of its own inset back, so its edge is the same on all four sides.
        let host = MenuRowHost(rootView: card.padding(.vertical, -MenuMetrics.menuChrome))
        host.frame.size = host.fittingSize
        host.autoresizingMask = [.width]
        item.view = host
        menu.addItem(item)
        self.menu = menu
        return menu
    }

    /// Closes the menu, then runs `action`.
    func later(_ action: @escaping @MainActor @Sendable () -> Void) {
        pending = action
        menu?.cancelTracking()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let action = pending else { return }
        pending = nil
        DispatchQueue.main.async(execute: action)
    }
}

/// One button of a card menu.
struct MenuItem: Identifiable {
    var id: String
    var icon: String
    var title: String
    var help: String = ""
    var enabled = true
    /// Chosen, for a pill that is a choice (the Brain in use).
    var on = false
    var action: () -> Void
}

/// The one measure of a menu card. The same inset is the card's edge, the gap between its sections and between
/// its buttons, and the room inside a button, so nothing in a card is spaced by a number of its own.
/// The glyph box gives every icon the same height, so the words under them share one baseline.
enum MenuMetrics {
    static let inset = Spacing.small
    static let glyph = Sizing.iconTile
    /// What `NSMenu` adds above and below a custom item view (and not beside it), measured on macOS 26.
    static let menuChrome: CGFloat = 5
}

/// An icon in the box every menu button gives its icon, centred, however short the glyph.
struct MenuGlyph: View {
    let name: String
    var size: IconSize = .large

    var body: some View {
        Image(systemName: name).font(.icon(size, weight: .semibold))
            .frame(width: MenuMetrics.glyph, height: MenuMetrics.glyph)
    }
}

/// The card: the menu's width, its inset, and its parts one under the other.
struct MenuCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MenuMetrics.inset) { content }
            .padding(MenuMetrics.inset)
            .frame(minWidth: Sizing.menuWidth, maxWidth: .infinity, alignment: .leading)
    }
}

/// The main actions: big pebbles, three to a row (two when there are four, so no row has one alone). A short last
/// row shares the full width between its buttons, so no row has a hole in it.
struct MenuGrid: View {
    let items: [MenuItem]

    private var columns: Int { items.count == 4 ? 2 : min(3, max(1, items.count)) }
    /// Cells across: six when rows of three must also split into two or one, else one per column.
    private var cells: Int { columns == 3 ? 6 : columns }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        Grid(horizontalSpacing: MenuMetrics.inset, verticalSpacing: MenuMetrics.inset) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in
                        QuickButton(icon: item.icon, verbatim: item.title, action: item.action)
                            .disabled(!item.enabled)
                            .help(item.help)
                            .gridCellColumns(cells / row.count)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Things to choose from, under a small heading: pills with an icon and a word, two to a row. A lone pill in the
/// last row takes both columns, so a section never has an empty half.
struct MenuPills: View {
    var title: String?
    let items: [MenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: MenuMetrics.inset) {
            if let title {
                Text(verbatim: title).font(Typeface.caption).foregroundStyle(Tone.muted)
                    .accessibilityAddTraits(.isHeader)
            }
            Grid(horizontalSpacing: MenuMetrics.inset, verticalSpacing: MenuMetrics.inset) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                    GridRow {
                        if start + 1 < items.count {
                            pill(items[start])
                            pill(items[start + 1])
                        } else {
                            pill(items[start]).gridCellColumns(2)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func pill(_ item: MenuItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: MenuMetrics.inset) {
                MenuGlyph(name: item.icon, size: .medium)
                Text(verbatim: item.title).font(Typeface.small.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.on ? AnyShapeStyle(OnTint()) : AnyShapeStyle(Tone.text))
            .padding(.horizontal, MenuMetrics.inset)
            .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
            .background(item.on ? AnyShapeStyle(TintFill()) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(PebbleButtonStyle())
        .disabled(!item.enabled)
        .help(item.help.isEmpty ? item.title : item.help)
        .accessibilityAddTraits(item.on ? .isSelected : [])
    }
}

/// What can't be undone, last and apart: one wide pebble with its words in the danger colour.
struct MenuDangerButton: View {
    let item: MenuItem

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: MenuMetrics.inset) {
                MenuGlyph(name: item.icon, size: .medium)
                Text(verbatim: item.title).font(Typeface.small.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(Tone.danger)
            .padding(.horizontal, MenuMetrics.inset)
            .frame(maxWidth: .infinity, minHeight: Sizing.control)
        }
        .buttonStyle(PebbleButtonStyle())
        .disabled(!item.enabled)
        .help(item.help)
    }
}

/// One icon in a pebble of its own, for the top right corner of a card's header (an Imp's Settings).
struct MenuCornerButton: View {
    let item: MenuItem

    var body: some View {
        Button(action: item.action) {
            MenuGlyph(name: item.icon, size: .medium)
                .frame(width: Sizing.control, height: Sizing.control)
        }
        .buttonStyle(PebbleButtonStyle())
        .disabled(!item.enabled)
        .help(item.help.isEmpty ? item.title : item.help)
        .accessibilityLabel(Text(verbatim: item.title))
    }
}

extension NSMenu {
    /// Opens the menu at the pointer of `event`: down from it where the card fits below, else up from it, and always
    /// whole on that screen. A card is one tall item, and AppKit's own placement of a context menu that doesn't fit
    /// below the pointer moves it to the top of the screen, far from the Imp that was clicked.
    func popUpCard(for event: NSEvent, in view: NSView) {
        guard let window = view.window else { return NSMenu.popUpContextMenu(self, with: event, for: view) }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen ?? NSScreen.main
        let height = size.height
        var top = pointer.y
        if let visible = screen?.visibleFrame {
            if top - height < visible.minY { top = pointer.y + height }        // no room below: open upwards
            top = min(max(top, visible.minY + height), visible.maxY)
        }
        _ = popUp(positioning: nil, at: NSPoint(x: pointer.x, y: top), in: nil)
    }
}
