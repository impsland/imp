import ImpDesign
import ImpKit
import SwiftUI

/// The two steps of the first run (Service, Model) on the iPhone, without any chrome, so the first-run
/// sheet and the Brain panel of an Imp show the very same content. The primary button is `FirstRunPhoneButton`,
/// pinned by the screen that shows this.
struct FirstRunPhoneFlow: View {
    @Bindable var flow: FirstRunModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address, key, model }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            switch flow.path.number {
            case 2: modelStep
            default: serviceStep
            }
            if let text = flow.problemText {
                StatusText(verbatim: text, symbol: "exclamationmark.circle", color: Tone.warnText)
                    .accessibilityLabel(Text(verbatim: text))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .impAnimation(ImpDesign.Motion.scene, value: flow.path.number)
        .onChange(of: flow.path.number) { _, _ in focus = nil }
    }

    // MARK: 1 Service

    private var serviceStep: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
                ForEach(flow.presets) { preset in
                    PresetTile(symbol: preset.symbol, title: preset.title,
                               detail: "", picked: flow.choice == preset,
                               link: preset.link, linkHelp: preset.link.absoluteString) {
                        flow.choose(preset)
                        focus = preset.isLocal ? .address : .key
                    }
                }
            }
            Titled(title: "firstrun.service.address") {
                TextField("firstrun.service.address", text: $flow.address, prompt: Text(verbatim: "https://…/v1"))
                    .impField(mono: true)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .focused($focus, equals: .address)
                    .submitLabel(flow.showsKey ? .next : .go)
                    .onSubmit { if flow.showsKey { focus = .key } else { flow.continueFromService() } }
            }
            if flow.showsKey {
                Titled(title: "firstrun.service.key") {
                    SecureField("firstrun.service.key", text: $flow.key)
                        .impField(mono: true)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .key)
                        .submitLabel(.go)
                        .onSubmit { flow.continueFromService() }
                }
            }
            if flow.path.step == .loadingModels {
                HStack(spacing: Spacing.small) {
                    ProgressView()
                    Text("firstrun.service.loading").font(Typeface.caption).foregroundStyle(Tone.muted)
                }
            } else {
                // One quiet line that guides the next step.
                Text(flow.needsHost && !flow.showsKey ? "firstrun.service.host_note" : "firstrun.service.note")
                    .font(Typeface.caption).foregroundStyle(Tone.muted)
            }
        }
        .disabled(flow.path.step == .loadingModels)
    }

    // MARK: 2 Model

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            TextField("firstrun.model.search", text: $flow.model, prompt: Text("firstrun.model.search"))
                .impField(mono: true)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .model)
                .submitLabel(.go).onSubmit { flow.check() }
            let shown = Array(flow.matchingModels.prefix(Self.listLimit))
            if !shown.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.self) { name in
                        PhoneModelRow(name: name, picked: name == flow.model) { flow.model = name; focus = nil }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.card))
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            }
        }
        .disabled(flow.path.isBusy)
    }

    /// A long list of models is searched, not scrolled through.
    private static let listLimit = 40
}

/// The step names, the indicator and its jumps: the same in the sheet and in the Brain panel.
struct FirstRunPhoneSteps: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        StepIndicator(steps: FirstRunPath.names.map { String(localized: String.LocalizationValue($0)) },
                      current: (flow.path.number ?? FirstRunPath.totalSteps) - 1,
                      reachable: { flow.canGo(to: $0 + 1) }) { flow.go(to: $0 + 1) }
    }
}

/// A model in the list: its name, ticked when it is the one.
private struct PhoneModelRow: View {
    let name: String
    let picked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                Text(verbatim: name).font(Typeface.mono).foregroundStyle(Tone.text).lineLimit(1)
                Spacer(minLength: Spacing.small)
                if picked { Image(systemName: "checkmark").font(.icon(.small, weight: .bold)).foregroundStyle(LegibleTint()) }
            }
            .padding(.horizontal, Spacing.medium)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The one primary button of the flow: Continue, Wake {name} up, Try again.
struct FirstRunPhoneButton: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        switch flow.primary {
        case .none: EmptyView()
        case .continueToModel: button("common.continue") { flow.continueFromService() }
        case .loading: button("common.continue") {}.disabled(true)
        case .wake: button(verbatim: words("firstrun.wake", flow.impName)) { flow.check() }
        case .tryAgain: button("common.try_again") { flow.check() }
        case .waking: button(verbatim: words("firstrun.check.running", flow.impName)) {}.disabled(true)
        }
    }

    private func button(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(WideButtonStyle())
    }

    /// For text that is already final (formatted at runtime), shown as it is.
    private func button(verbatim title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }.buttonStyle(WideButtonStyle())
    }
}
