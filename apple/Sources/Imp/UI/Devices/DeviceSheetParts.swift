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
    /// Opens the Hop's sheet.
    let hop: () -> Void

    /// The linked device behind a node.
    func peer(_ node: String) -> DeviceLink.Peer? { model.link.peers.first { $0.id.uuidString == node } }

    func name(of node: String) -> String { map.title(of: node) }

    func symbol(of node: String) -> String { map.node(node)?.symbol ?? "questionmark" }

    var thisMac: String { DeviceMap.thisMacID }

    /// The line between this Mac and the device `node`, the one its plugs are on: through the Hop or direct.
    func connection(to node: String) -> DeviceMap.Channel? {
        map.channels.first { $0.from == node || $0.to == node }
    }
}

// MARK: Rows

/// How a thing stands, as a card across the sheet: a picture in the state's colour and a word.
struct StatusLine: View {
    let symbol: String
    var tone: Color = Tone.muted
    let text: String

    var body: some View {
        Label { Text(verbatim: text).font(Typeface.label).foregroundStyle(Tone.text).lineLimit(1) }
            icon: { Image(systemName: symbol).font(.icon(.small)).foregroundStyle(tone) }
            .pebble()
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
    init(verbatim title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        label = FitLabel(verbatim: title, systemImage: symbol)
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) { label }
            .buttonStyle(.imp(role == .destructive ? .destructive : .secondary, small: true))
    }
}

/// The main actions of a sheet: one row across the sheet's whole width, the buttons sharing it equally, or
/// one under the other (each as wide as the sheet) when their words don't fit side by side. Never a short
/// row on the left with the space on the right left empty.
struct SheetActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.small) { content }
            VStack(spacing: Spacing.small) { content }
        }
        .environment(\.impPillFills, true)
        .frame(maxWidth: .infinity)
    }
}
