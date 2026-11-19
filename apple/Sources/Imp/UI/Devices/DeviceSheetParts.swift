import ImpDesign
import ImpKit
import SwiftUI

/// What the sheets' pages need from the screen: the model, the map as drawn, and how to open another sheet,
/// the Link sheet, or ask to forget a device.
@MainActor
struct DeviceContext {
    let model: AppModel
    let router: HomeRouter
    let map: DeviceMap
    let select: (DeviceSelection?) -> Void
    let link: () -> Void
    let forget: (DeviceLink.Peer) -> Void
    let forgetEveryone: () -> Void

    /// The linked device behind a node.
    func peer(_ node: String) -> DeviceLink.Peer? { model.link.peers.first { $0.id.uuidString == node } }

    func name(of node: String) -> String { map.title(of: node) }

    func symbol(of node: String) -> String { map.node(node)?.symbol ?? "questionmark" }

    var thisMac: String { DeviceMap.thisMacID }
}

// MARK: Rows

/// How a thing stands, as one line: a picture in the state's colour and a word.
struct StatusLine: View {
    let symbol: String
    var tone: Color = Tone.muted
    let text: String

    var body: some View {
        Label { Text(verbatim: text).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1) }
            icon: { Image(systemName: symbol).font(.icon(.small)).foregroundStyle(tone) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

/// One line in a card or on its own: a leading picture, a title and what goes at the end.
struct SheetRow<Leading: View, Trailing: View>: View {
    let title: String
    var mono = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            leading
            Text(verbatim: title).font(mono ? Typeface.mono : Typeface.body).foregroundStyle(Tone.text).lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.small)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pebble()
    }
}

extension SheetRow where Leading == IconTile, Trailing == EmptyView {
    init(_ title: String, symbol: String, mono: Bool = false) {
        self.init(title: title, mono: mono, leading: { IconTile(systemName: symbol) }, trailing: { EmptyView() })
    }
}

/// A row that opens another sheet: a leading picture, a title, what goes before the chevron (what the thing is to
/// this sheet's subject, a small tag, never a sentence) and the chevron.
struct JumpRow<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.cozy) {
                leading
                Text(verbatim: title).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1)
                Spacer(minLength: Spacing.small)
                trailing
                Image(systemName: "chevron.right").font(.icon(.tiny)).foregroundStyle(Tone.faint).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pebble(hover: true)
    }
}

extension JumpRow where Leading == IconTile, Trailing == Text {
    /// A device or thing with its picture and a short tag for how it relates to the sheet's subject.
    init(_ title: String, symbol: String, tag: LocalizedStringKey, action: @escaping () -> Void) {
        self.init(title: title, leading: { IconTile(systemName: symbol) },
                  trailing: { Text(tag).font(Typeface.small).foregroundStyle(Tone.muted) }, action: action)
    }
}

extension JumpRow where Leading == IconTile, Trailing == EmptyView {
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.init(title: title, leading: { IconTile(systemName: symbol) }, trailing: { EmptyView() }, action: action)
    }
}

/// An Imp in a list: its colour, its name and where its body is (a walking mark for a visitor). Opens its sheet.
struct ImpJumpRow: View {
    let contact: DeviceMap.Contact
    let place: String
    let visitor: Bool
    let open: () -> Void

    var body: some View {
        JumpRow(title: contact.name, leading: {
            Circle().fill(Color.imp(contact.hue)).frame(width: Spacing.cozy, height: Spacing.cozy)
        }, trailing: {
            HStack(spacing: Spacing.small) {
                if visitor { Image(systemName: "figure.walk.arrival").font(.icon(.tiny)).accessibilityHidden(true) }
                Text(verbatim: place).font(Typeface.small).lineLimit(1)
            }
            .foregroundStyle(Tone.muted)
        }, action: open)
        .accessibilityLabel(Text(verbatim: "\(contact.name), \(place)"))
    }
}

/// A row with a switch: a picture, a title, an optional help and the switch.
struct SwitchRow: View {
    let symbol: String
    let title: String
    var info: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        SheetRow(title: title, leading: { IconTile(systemName: symbol) }, trailing: {
            if let info { InfoTip(info) }
            Toggle(isOn: $isOn) { Text(verbatim: title) }.labelsHidden().toggleStyle(.impSwitchBare)
        })
    }
}

/// The two places an Imp is tied to: the device its body is on, and the device it thinks on (none when that is a device
/// this Mac is not linked with). Each opens that device.
struct PlaceRows: View {
    let ctx: DeviceContext
    let on: String
    let thinksOn: String?

    var body: some View {
        VStack(spacing: Spacing.small) {
            JumpRow(ctx.name(of: on), symbol: ctx.symbol(of: on), tag: "devices.place.body") { ctx.select(.node(on)) }
            if let thinksOn {
                JumpRow(ctx.name(of: thinksOn), symbol: ctx.symbol(of: thinksOn), tag: "devices.place.mind") { ctx.select(.node(thinksOn)) }
            } else {
                SheetRow(String(localized: "devices.unknown_device"), symbol: "questionmark")
            }
        }
    }
}

// MARK: Tools

/// One tool switch: its picture, title and where the switch is stored.
struct ToolSwitch: Identifiable {
    var id: String
    var symbol: String
    var title: String
    var isOn: Binding<Bool>
}

/// A card of tool switches that is a row of pictures until it is opened: the tools that are on, each with its name on
/// hover, and the chevron that opens the switches. Long lists do not take the sheet.
struct ToolSwitchCard: View {
    let title: LocalizedStringKey
    var info: LocalizedStringKey?
    let tools: [ToolSwitch]
    @State private var open = false

    var body: some View {
        Card(title, icon: "wrench.and.screwdriver.fill", info: info) {
            Button { open.toggle() } label: {
                HStack(spacing: Spacing.tight) {
                    Text(verbatim: "\(tools.filter { $0.isOn.wrappedValue }.count)/\(tools.count)")
                        .font(Typeface.label.monospacedDigit()).foregroundStyle(Tone.muted)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.icon(.tiny)).foregroundStyle(Tone.muted)
                }
                .frame(minHeight: Sizing.iconTile)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("devices.tools.toggle"))
        } content: {
            if open {
                VStack(spacing: Spacing.small) {
                    ForEach(tools) { SwitchRow(symbol: $0.symbol, title: $0.title, isOn: $0.isOn) }
                }
            } else {
                ToolStrip(tools: tools.filter { $0.isOn.wrappedValue }.map { ($0.symbol, $0.title) })
            }
        }
    }
}

/// Tools as a row of pictures, each named on hover.
struct ToolStrip: View {
    let tools: [(symbol: String, title: String)]

    var body: some View {
        FlowLayout(spacing: Spacing.small, lineSpacing: Spacing.small) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                IconTile(systemName: tool.symbol).help(tool.title).accessibilityLabel(Text(verbatim: tool.title))
            }
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.iconTile, alignment: .leading)
    }
}

// MARK: Actions

/// A small button with a picture, for the main actions under a sheet's status.
struct SheetAction: View {
    let label: FitLabel
    var role: ButtonRole?
    let action: () -> Void

    init(title: LocalizedStringKey, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        label = FitLabel(title, systemImage: symbol)
        self.role = role
        self.action = action
    }

    /// For a name that is not a key, such as a device's.
    init(verbatim title: String, symbol: String, action: @escaping () -> Void) {
        label = FitLabel(verbatim: title, systemImage: symbol)
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { label }
            .buttonStyle(.imp(role == .destructive ? .destructive : .secondary, small: true))
    }
}

/// The main actions of a sheet, side by side and wrapping.
struct SheetActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: Spacing.small, lineSpacing: Spacing.small) { content }
    }
}
