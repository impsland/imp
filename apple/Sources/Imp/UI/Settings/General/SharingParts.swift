import ImpDesign
import ImpKit
import SwiftUI

/// One list of the Sharing page: a header with its help, and what is in it. Every header has the same
/// icon-only actions in the same order (add, import a kit, share all) before the help, so the three lists
/// are the same in every way but their items. With nothing in it a list is only its header, which says so on
/// the same line, so an empty list takes no room and the actions never move.
struct SharingSection<Rows: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let info: LocalizedStringKey
    /// What the add button is called, and what it does.
    let add: LocalizedStringKey
    let onAdd: () -> Void
    /// How many rows there are.
    let count: Int
    /// Every row as one kit (empty when there is nothing to share, and then it is switched off).
    let kit: Kit
    /// Whether this header carries the page's import anchor (exactly one does).
    var importAnchor = false
    @ViewBuilder var rows: Rows

    init(_ title: LocalizedStringKey, symbol: String, info: LocalizedStringKey, add: LocalizedStringKey, onAdd: @escaping () -> Void,
         count: Int, kit: Kit, importAnchor: Bool = false, @ViewBuilder rows: () -> Rows) {
        self.title = title; self.symbol = symbol; self.info = info; self.add = add; self.onAdd = onAdd
        self.count = count; self.kit = kit; self.importAnchor = importAnchor; self.rows = rows()
    }

    var body: some View {
        PanelList(title, icon: symbol, info: info, accessory: {
            HStack(spacing: Spacing.small) {
                if count == 0 { Text("sharing.none").font(Typeface.small).foregroundStyle(Tone.muted) }
                HoverIconButton(systemName: SectionAction.add, help: add, action: onAdd)
                if importAnchor { ImportKitButton(imp: nil).settingAnchor(.sharingImport) } else { ImportKitButton(imp: nil) }
                ShareKitButton(kit: kit, help: "sharing.share_all").disabled(count == 0)
            }
        }) {
            if count > 0 { VStack(spacing: Spacing.snug) { rows } }
        }
    }
}

/// One row of a Sharing list, the same for every kind of item: its picture, a name over one line saying whose it
/// is, then change, share as a kit and the switch, always in that order. What only some items can do (open in
/// the Imp's settings, save as a sticker) is in the row's menu, so the rows stay alike.
struct SharingRow<Leading: View, Detail: View, Menu: View>: View {
    /// The name, one line: the whole of it is the tooltip.
    let title: String
    let kit: Kit
    let isOn: Binding<Bool>
    let edit: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var detail: Detail
    @ViewBuilder var menu: Menu

    var body: some View {
        HStack(spacing: Spacing.small) {
            leading.frame(width: Sizing.iconTile, height: Sizing.iconTile).opacity(isOn.wrappedValue ? 1 : Opacity.dimmed)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(verbatim: title).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.tail)
                    .help(Text(verbatim: title))
                // One small line tall whatever it holds (a label or a row of dots).
                ZStack(alignment: .leading) {
                    Text(verbatim: " ").font(Typeface.small).hidden()
                    detail
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HoverIconButton(systemName: "pencil", help: "Change \(title)", action: edit)
            ShareKitButton(kit: kit, help: "Share as a kit")
            Toggle(isOn: isOn) { Text(verbatim: title) }
                .labelsHidden().toggleStyle(.impSwitchBare)
                .help(isOn.wrappedValue ? "Turn off \(title)" : "Turn on \(title)")
                .accessibilityLabel(Text(isOn.wrappedValue ? "Turn off \(title)" : "Turn on \(title)"))
        }
        .frame(minHeight: Sizing.control)
        .pebble()
        .contextMenu {
            Button("Change…", action: edit)
            menu
        }
    }
}

extension SharingRow where Menu == EmptyView {
    init(title: String, kit: Kit, isOn: Binding<Bool>, edit: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading, @ViewBuilder detail: () -> Detail) {
        self.init(title: title, kit: kit, isOn: isOn, edit: edit, leading: leading, detail: detail, menu: { EmptyView() })
    }
}
