import ImpDesign
import ImpKit
import SwiftUI

/// One server this iPhone uses, as a card: The Den (the gallery) or The Hop (lets devices find each
/// other from anywhere). The choice is one menu, "Check" sits at the trailing edge of the row it tests
/// and its result is under it. Either can be off.
struct ServerCard: View {
    let hub: LinkHub
    let kind: ServerKind
    @State private var text = ""
    @State private var custom = false
    @State private var invalid: String?
    /// What the last check found: nil before one, while it runs and after the address changes.
    @State private var reached: Bool?
    @State private var checking = false
    @FocusState private var focused: Bool

    private var choice: ServerChoice { custom ? .custom : ServerChoice.of(text, kind) }
    private var isSet: Bool { kind == .den ? DenServer(text) != nil : HopServer(text) != nil }

    var body: some View {
        Card(kind == .den ? "servers.den.title" : "servers.hop.title", icon: kind == .den ? "tray.full" : "point.3.connected.trianglepath.dotted",
             info: kind == .den ? "servers.den.about" : "servers.hop.about") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.small) { picker; Spacer(minLength: 0); check }
                VStack(alignment: .leading, spacing: Spacing.small) { picker; check }
            }
            if choice == .custom {
                TextField(kind == .den ? "phone.server.placeholder_den" : "phone.server.placeholder_hop", text: $text)
                    .impField(mono: true)
                    .focused($focused)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            }
            if let invalid {
                StatusText(verbatim: invalid, symbol: "exclamationmark.triangle.fill", color: Tone.warnText)
            } else if checking {
                StatusText(text: "servers.state_checking", symbol: "hourglass")
            } else if let reached {
                StatusText(text: reached ? "servers.state_ok" : "servers.state_fail",
                           symbol: reached ? "checkmark.circle.fill" : "xmark.octagon.fill", color: reached ? Tone.good : Tone.danger)
            }
        }
        .onAppear {
            text = kind == .den ? hub.den : hub.hop
            custom = ServerChoice.of(text, kind) == .custom
        }
        .onChange(of: text) { reached = nil; checking = false }
        .impAnimation(ImpDesign.Motion.smooth, value: choice)
    }

    private var picker: some View {
        ImpPicker("phone.server.choice", selection: Binding(get: { choice }, set: { pick($0) }),
                  options: ServerChoice.allCases, symbol: symbol(choice), title: name)
    }

    @ViewBuilder private var check: some View {
        if isSet {
            Button { reach() } label: { FitLabel("common.check", systemImage: "checkmark.circle") }
                .buttonStyle(.quiet).disabled(checking)
        }
    }

    private func apply(_ value: String) -> Bool { kind == .den ? hub.setDen(value) : hub.setHop(value) }

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
        case .thisComputer: String(localized: "servers.preset.local")
        case .custom: String(localized: "servers.preset.custom")
        case .off: String(localized: "servers.preset.off")
        }
    }

    private func symbol(_ option: ServerChoice) -> String {
        switch option {
        case .imps: "server.rack"
        case .thisComputer: "desktopcomputer"
        case .custom: "pencil"
        case .off: "power"
        }
    }
}
