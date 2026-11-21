import ImpDesign
import ImpKit
import SwiftUI

/// One server (the Hop) as one compact card, the same wherever it is shown (the Link sheet's popover, the Hop's sheet).
/// The header carries what is live: a status icon (hover for the address and the state) and Check, which
/// shows its own progress and result. Under it, the choice of server as buttons (Imp's servers,
/// Custom, Off) and the address. The address row is always there, dimmed and locked unless Custom
/// is chosen, so the card is the same size whatever is picked. A failure floats as a notice, so nothing
/// is ever inserted into the card. The state lives in `ServerSetting`.
struct ServerCard: View {
    let kind: ServerKind
    /// Under a header that already names it (a sheet), the card has no title of its own: its state and Check sit
    /// by the address, so the state is shown once.
    var hosted = false
    /// How the map says the server's node stands, for the state when nothing was checked here.
    var link: DeviceMap.State = .offline
    @Binding var text: String
    @State private var setting: ServerSetting
    @FocusState private var typing: Bool
    @Environment(\.postNotice) private var postNotice

    /// `choice` starts the card with that choice picked (a design scene shows Custom before an address is typed).
    init(kind: ServerKind, text: Binding<String>, choice: ServerChoice? = nil, hosted: Bool = false, link: DeviceMap.State = .offline) {
        self.kind = kind
        self.hosted = hosted
        self.link = link
        _text = text
        var setting = ServerSetting(kind: kind, text: text.wrappedValue)
        if let choice { setting.pick(choice) }
        _setting = State(initialValue: setting)
    }

    var body: some View {
        Card(hosted ? nil : "servers.hop.title", icon: kind.symbol, info: "servers.hop.about") {
            HStack(spacing: Spacing.cozy) {
                stateIcon
                checkButton
            }
        } content: {
            ImpSegmented("servers.hop.title",
                         selection: Binding(get: { setting.choice }, set: { text = setting.pick($0) }),
                         options: ServerChoice.allCases, title: \.title, symbol: \.symbol, fills: true)
            HStack(spacing: Spacing.cozy) {
                if hosted { stateIcon }
                TextField(String("hop.example.com:4677"),
                          text: Binding(get: { setting.text }, set: { setting.edit($0); text = $0 }))
                    .impField(mono: true).autocorrectionDisabled()
                    .focused($typing)
                    .disabled(!setting.showsAddress)
                    .opacity(setting.showsAddress ? 1 : Opacity.dimmed)
                    .accessibilityHint(Text("servers.address_hint"))
                if hosted { checkButton }
            }
        }
        .onChange(of: setting.showsAddress) { _, shows in if shows { typing = true } }
        .onChange(of: text) { _, new in if new != setting.text { setting = ServerSetting(kind: kind, text: new) } }
        .onChange(of: setting.status) { _, status in
            if case .unreachable = status { postNotice(.error(failure)) }
        }
        .onChange(of: typing) { _, now in
            if !now, case .problem(let problem) = setting.status { postNotice(.warning(problem)) }
        }
    }

    /// How the server stands, as one icon in the header. Hover for the address and the words.
    private var stateIcon: some View {
        let standing = HopStanding(setting, link: link)
        let state = stateWords(standing)
        let help = setting.inUse.map { words("servers.state_help", $0, state) } ?? state
        return Image(systemName: standing.symbol).font(.icon(.small)).foregroundStyle(standing.tone)
            .frame(width: Sizing.mark)
            .help(help)
            .accessibilityElement().accessibilityLabel(Text(verbatim: help))
    }

    private var checkButton: some View {
        Button { check() } label: { StatefulLabel("common.check", symbol: "checkmark.circle", state: checkState) }
            .buttonStyle(.imp(.secondary, small: true)).disabled(!setting.canCheck)
    }

    /// What the state is called: the reason when what is typed is not an address, else the standing's word.
    private func stateWords(_ standing: HopStanding) -> String {
        if case .problem(let problem) = setting.status { return problem }
        if standing == .unreachable { return failure }
        if standing == .offline || standing == .connected, setting.choice == .imps { return String(localized: "servers.preset.imp_note") }
        return standing.word
    }

    /// Why a check failed. On This computer it is almost always that nothing runs the server here yet.
    private var failure: String {
        guard ServerKind.isOnThisDevice(setting.text) else { return String(localized: "servers.state_fail") }
        return words("servers.state_fail_local", String(localized: "servers.hop.title"))
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
    var symbol: String { "arrow.triangle.swap" }
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
