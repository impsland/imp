import ImpDesign
import ImpKit
import SwiftUI

/// One server (The Hop on Devices, The Den on Sharing) as one card, the same on both pages: what it is and
/// whether it answers on top (the address in use, its state, and Check on the trailing edge), then the
/// choice of server (Imp's servers, This computer, Custom, Off) and, for Custom, the address. The state
/// lives in `ServerSetting`.
struct ServerCard: View {
    let kind: ServerKind
    @Binding var text: String
    @State private var setting: ServerSetting

    init(kind: ServerKind, text: Binding<String>) {
        self.kind = kind
        _text = text
        _setting = State(initialValue: ServerSetting(kind: kind, text: text.wrappedValue))
    }

    var body: some View {
        Card(kind == .den ? "servers.den.title" : "servers.hop.title", icon: kind.symbol,
             info: kind == .den ? "servers.den.about" : "servers.hop.about") {
            statusRow
            FieldRow("servers.choice") {
                ImpPicker("servers.choice", selection: Binding(get: { setting.choice }, set: { text = setting.pick($0) }),
                          options: ServerChoice.allCases, symbol: setting.choice.symbol, title: \.title)
            }
            if setting.showsAddress {
                FieldRow("servers.address") {
                    TextField(String(kind == .den ? "den.example.com" : "hop.example.com:4677"),
                              text: Binding(get: { setting.text }, set: { setting.edit($0); text = $0 }))
                        .impField(mono: true).autocorrectionDisabled()
                        .accessibilityHint(Text("servers.address_hint"))
                }
            }
        }
        .onChange(of: text) { _, new in if new != setting.text { setting = ServerSetting(kind: kind, text: new) } }
    }

    /// The server in use and how it answers, with Check on the trailing edge: one status, one action.
    private var statusRow: some View {
        HStack(spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(verbatim: headline).font(setting.inUse == nil ? Typeface.label : Typeface.mono)
                    .foregroundStyle(Tone.text).lineLimit(1).truncationMode(.middle)
                    .help(headline)
                state
            }
            Spacer(minLength: Spacing.small)
            if setting.inUse != nil {
                Button { check() } label: { FitLabel("common.check", systemImage: "checkmark.circle") }
                    .buttonStyle(.imp(.secondary, small: true)).disabled(!setting.canCheck)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
        .pebble()
        .accessibilityElement(children: .combine)
    }

    /// The address in use, or what the choice is when there is none.
    private var headline: String { setting.inUse ?? ServerChoice.off.title }

    @ViewBuilder private var state: some View {
        switch setting.status {
        case .off: StatusText(verbatim: words(kind == .den ? "servers.den.off_note" : "servers.hop.off_note"), symbol: "circle", color: Tone.muted)
        case .problem(let problem): StatusText(verbatim: problem, symbol: "exclamationmark.triangle.fill", color: Tone.warnText).help(problem)
        case .ready: StatusText(text: setting.choice == .imps ? "servers.preset.imp_note" : "servers.state_unchecked", symbol: "circle.fill", color: Tone.good)
        case .checking: StatusText(text: "servers.state_checking", symbol: "hourglass", color: Tone.muted)
        case .reachable: StatusText(text: "servers.state_ok", symbol: "checkmark.circle.fill", color: Tone.good)
        case .unreachable: StatusText(text: "servers.state_fail", symbol: "xmark.octagon.fill", color: Tone.danger)
        }
    }

    private func check() {
        guard let address = setting.startCheck() else { return }
        let kind = kind
        Task {
            let ok = await ServerProbe.reachable(kind, address)
            setting.finishCheck(address, reachable: ok)
        }
    }
}

extension ServerKind {
    var symbol: String { self == .den ? "tray.full.fill" : "arrow.triangle.swap" }
}

extension ServerChoice {
    var symbol: String {
        switch self {
        case .imps: "flame.fill"
        case .thisComputer: "desktopcomputer"
        case .custom: "pencil"
        case .off: "power"
        }
    }

    var title: String {
        switch self {
        case .imps: String(localized: "servers.preset.imp")
        case .thisComputer: String(localized: "servers.preset.local")
        case .custom: String(localized: "servers.preset.custom")
        case .off: String(localized: "servers.preset.off")
        }
    }
}

/// What a screen that needs the Den says while there is none: no blank screen and no spinner.
struct DenNeeded: View {
    var body: some View {
        StatusText(text: "servers.den.needed", symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
    }
}
