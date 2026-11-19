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
        let host = MenuRowHost(rootView: card)
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

/// The card: the menu's width, its inset, and its parts one under the other.
struct MenuCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) { content }
            .padding(Spacing.medium)
            .frame(minWidth: Sizing.menuWidth, maxWidth: .infinity, alignment: .leading)
    }
}

/// The main actions: big pebbles, three to a row (two when there are four, so no row has one alone).
struct MenuGrid: View {
    let items: [MenuItem]

    private var columns: Int { items.count == 4 ? 2 : min(3, max(1, items.count)) }

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        Grid(horizontalSpacing: Spacing.snug, verticalSpacing: Spacing.snug) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in
                        QuickButton(icon: item.icon, verbatim: item.title, action: item.action)
                            .disabled(!item.enabled)
                            .help(item.help)
                    }
                    // A short last row keeps the width of the others.
                    ForEach(row.count..<columns, id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Things to choose from, under a small heading: pills with an icon and a word, two to a row.
struct MenuPills: View {
    var title: String?
    let items: [MenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let title {
                Text(verbatim: title).font(Typeface.caption).foregroundStyle(Tone.muted)
                    .accessibilityAddTraits(.isHeader)
            }
            Grid(horizontalSpacing: Spacing.snug, verticalSpacing: Spacing.snug) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                    GridRow {
                        pill(items[start])
                        if start + 1 < items.count { pill(items[start + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func pill(_ item: MenuItem) -> some View {
        Button(action: item.action) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: item.icon).font(.icon(.small, weight: .semibold))
                Text(verbatim: item.title).font(Typeface.small.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.on ? AnyShapeStyle(OnTint()) : AnyShapeStyle(Tone.text))
            .padding(.horizontal, Spacing.small)
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
            Label(item.title, systemImage: item.icon)
                .font(Typeface.label)
                .foregroundStyle(Tone.danger)
                .frame(maxWidth: .infinity, minHeight: Sizing.control)
        }
        .buttonStyle(PebbleButtonStyle())
        .disabled(!item.enabled)
        .help(item.help)
    }
}
