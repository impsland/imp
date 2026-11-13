import ImpDesign
import ImpKit
import SwiftUI

/// One server (The Hop on Devices, The Den on Sharing) as one compact card, the same on both pages. The
/// header carries what is live: a status icon (hover for the address and the state) and Check, which
/// shows its own progress and result. Under it, the choice of server as buttons (Imp's servers, This
/// computer, Custom, Off) and, for Custom only, the address. A failure floats as a notice, so nothing
/// is ever inserted into the page. The state lives in `ServerSetting`.
struct ServerCard: View {
    let kind: ServerKind
    @Binding var text: String
    @State private var setting: ServerSetting
    @FocusState private var typing: Bool
    @Environment(\.postNotice) private var postNotice

    init(kind: ServerKind, text: Binding<String>) {
        self.kind = kind
        _text = text
        _setting = State(initialValue: ServerSetting(kind: kind, text: text.wrappedValue))
    }

    var body: some View {
        Card(kind == .den ? "servers.den.title" : "servers.hop.title", icon: kind.symbol,
             info: kind == .den ? "servers.den.about" : "servers.hop.about") {
            HStack(spacing: Spacing.cozy) {
                stateIcon
                Button { check() } label: { StatefulLabel("common.check", symbol: "checkmark.circle", state: checkState) }
                    .buttonStyle(.imp(.secondary, small: true)).disabled(!setting.canCheck)
            }
        } content: {
            ImpSegmented(kind == .den ? "servers.den.title" : "servers.hop.title",
                         selection: Binding(get: { setting.choice }, set: { text = setting.pick($0) }),
                         options: ServerChoice.allCases, title: \.title, symbol: \.symbol, fills: true)
            if setting.showsAddress {
                TextField(String(kind == .den ? "den.example.com" : "hop.example.com:4677"),
                          text: Binding(get: { setting.text }, set: { setting.edit($0); text = $0 }))
                    .impField(mono: true).autocorrectionDisabled()
                    .focused($typing)
                    .accessibilityHint(Text("servers.address_hint"))
            }
        }
        .onChange(of: text) { _, new in if new != setting.text { setting = ServerSetting(kind: kind, text: new) } }
        .onChange(of: setting.status) { _, status in
            if case .unreachable = status { postNotice(.error(failure)) }
        }
        .onChange(of: typing) { _, now in
            if !now, case .problem(let problem) = setting.status { postNotice(.warning(problem)) }
        }
    }

    /// How the server stands, as one icon in the header; hover for the address and the words.
    private var stateIcon: some View {
        let (symbol, color, state) = appearance
        let help = setting.inUse.map { words("servers.state_help", $0, state) } ?? state
        return Image(systemName: symbol).font(.icon(.small)).foregroundStyle(color)
            .frame(width: Sizing.mark)
            .help(help)
            .accessibilityElement().accessibilityLabel(Text(verbatim: help))
    }

    private var appearance: (String, Color, String) {
        switch setting.status {
        case .off: ("circle", Tone.muted, String(localized: kind == .den ? "servers.den.off_note" : "servers.hop.off_note"))
        case .problem(let problem): ("exclamationmark.triangle.fill", Tone.warnText, problem)
        case .ready: ("circle.fill", Tone.good, String(localized: setting.choice == .imps ? "servers.preset.imp_note" : "servers.state_unchecked"))
        case .checking: ("hourglass", Tone.muted, String(localized: "servers.state_checking"))
        case .reachable: ("checkmark.circle.fill", Tone.good, String(localized: "servers.state_ok"))
        case .unreachable: ("xmark.octagon.fill", Tone.danger, failure)
        }
    }

    /// Why a check failed. On This computer it is almost always that nothing runs the server here yet.
    private var failure: String {
        guard ServerKind.isOnThisDevice(setting.text) else { return String(localized: "servers.state_fail") }
        return words("servers.state_fail_local", String(localized: kind == .den ? "servers.den.title" : "servers.hop.title"))
    }

    /// Check carries the result of the last check on its own icon.
    private var checkState: ActionState {
        switch setting.status {
        case .checking: .working
        case .reachable: .done
        case .unreachable: .failed
        default: .idle
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
        case .custom: "pencil"
        case .off: "power"
        }
    }

    var title: String {
        switch self {
        case .imps: String(localized: "servers.preset.imp")
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
