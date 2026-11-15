import ImpDesign
import ImpKit
import SwiftUI

/// The Hop (lets devices find each other from anywhere), as a compact card. The header holds a status icon and Check, which carries its own progress and result.
/// Under it the choice is a row of buttons and, for Custom only, the address. Failures float as notices, so
/// nothing is inserted into the page. It can be off.
struct ServerCard: View {
    let hub: LinkHub
    private let kind = ServerKind.hop
    @State private var text = ""
    @State private var custom = false
    @State private var invalid: String?
    /// What the last check found: nil before one, while it runs and after the address changes.
    @State private var reached: Bool?
    @State private var checking = false
    @FocusState private var focused: Bool
    @Environment(\.postNotice) private var post

    private var choice: ServerChoice { custom ? .custom : ServerChoice.of(text, kind) }
    private var isSet: Bool { HopServer(text) != nil }

    var body: some View {
        Card("servers.hop.title", icon: "point.3.connected.trianglepath.dotted", info: "servers.hop.about") {
            HStack(spacing: Spacing.cozy) {
                stateIcon
                Button { reach() } label: { StatefulLabel("common.check", symbol: "checkmark.circle", state: checkState) }
                    .buttonStyle(.quiet).disabled(!isSet || checking)
            }
        } content: {
            ImpSegmented("servers.hop.title",
                         selection: Binding(get: { choice }, set: { pick($0) }),
                         options: ServerChoice.allCases, title: name, symbol: symbol, fills: true)
            if choice == .custom {
                TextField("phone.server.placeholder_hop", text: $text)
                    .impField(mono: true)
                    .focused($focused)
                    .codeEntry(.address)
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            }
        }
        .onAppear {
            text = hub.hop
            custom = ServerChoice.of(text, kind) == .custom
        }
        .onChange(of: text) { reached = nil; checking = false }
        .onChange(of: invalid) { _, problem in if let problem { post(.warning(problem)) } }
        .onChange(of: reached) { _, found in if found == false { post(.error(String(localized: "servers.state_fail"))) } }
        .impAnimation(ImpDesign.Motion.smooth, value: choice)
    }

    /// How the server stands, as one icon in the header.
    private var stateIcon: some View {
        let (symbol, color, words): (String, Color, String) = {
            if let invalid { return ("exclamationmark.triangle.fill", Tone.warnText, invalid) }
            if checking { return ("hourglass", Tone.muted, String(localized: "servers.state_checking")) }
            if let reached {
                return (reached ? "checkmark.circle.fill" : "xmark.octagon.fill", reached ? Tone.good : Tone.danger,
                        String(localized: reached ? "servers.state_ok" : "servers.state_fail"))
            }
            if isSet { return ("circle.fill", Tone.good, String(localized: "servers.state_unchecked")) }
            return ("circle", Tone.muted, String(localized: "servers.hop.off_note"))
        }()
        return Image(systemName: symbol).font(.icon(.small)).foregroundStyle(color)
            .frame(width: Sizing.mark)
            .accessibilityElement().accessibilityLabel(Text(verbatim: words))
    }

    private var checkState: ActionState {
        if checking { return .working }
        guard let reached else { return .idle }
        return .result(reached)
    }

    private func apply(_ value: String) -> Bool { hub.setHop(value) }

    /// Asks the server at the typed address whether it answers.
    private func reach() {
        let address = text
        checking = true
        reached = nil
        Task {
            let ok = await ServerProbe.reachable(kind, address)
            guard address == text else { return }
            reached = ok
            checking = false
        }
    }

    private func pick(_ option: ServerChoice) {
        custom = option == .custom
        if let address = option.address(kind) {
            text = address
            commit(address)
        } else if ServerChoice.of(text, kind) != .custom {
            text = ""
            commit("")
        }
    }

    private func commit(_ value: String? = nil) {
        let value = value ?? text
        invalid = apply(value) ? nil : kind.problem(with: value)
    }

    private func name(_ option: ServerChoice) -> String {
        switch option {
        case .imps: String(localized: "servers.preset.imp")
        case .custom: String(localized: "servers.preset.custom")
        case .off: String(localized: "servers.preset.off")
        }
    }

    private func symbol(_ option: ServerChoice) -> String {
        switch option {
        case .imps: "server.rack"
        case .custom: "pencil"
        case .off: "power"
        }
    }
}
