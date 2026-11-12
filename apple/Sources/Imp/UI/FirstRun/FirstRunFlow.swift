import ImpDesign
import ImpKit
import SwiftUI

/// The first run on one page, without any modal chrome, so the sheet and the Brain panel of an Imp show the
/// very same content: the choice (Remote or Local), the address, the key and the model (left blank, the first
/// one that chats is used). Put `FirstRunStatus` and `FirstRunPrimaryButton` under it. Nothing here moves
/// when something goes wrong: problems and progress have their own place beside the button. The flow is
/// over when `flow.path.step == .done`: the Imp is awake.
struct FirstRunFlow: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        ServiceFields(choice: flow.choice, found: { flow.running($0) != nil }, pick: { flow.choose($0) },
                      address: $flow.address, key: $flow.key, showsKey: flow.showsKey,
                      submit: { flow.wakeUp() }) {
            FieldRow("brain.model", info: "settings.service.model.info") {
                ModelField(model: $flow.model, placeholder: "firstrun.model.search") { [address = flow.address, key = flow.key] in
                    try await OpenAIClient(baseURL: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                           apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines)).models()
                }
                .disabled(!ServicePreset.isValidAddress(flow.address))
            }
        }
        .disabled(flow.path.isBusy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { flow.discover() }
    }
}

/// What the flow is doing or what went wrong, in one line of its own: it takes the same room whether it
/// says something or not, so the page never shifts. The full sentence is in the tooltip.
struct FirstRunStatus: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        Group {
            if let text = flow.problemText {
                StatusText(verbatim: text, symbol: "exclamationmark.circle", color: Tone.warnText)
                    .help(text)
                    .accessibilityLabel(Text(verbatim: text))
            } else if flow.path.step == .loadingModels || flow.path.step == .checking {
                ProgressView().controlSize(.small)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
    }
}

/// The one primary button of the first run: Wake {name} up, or Try again after a failure. Return presses it.
struct FirstRunPrimaryButton: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        switch flow.primary {
        case .none: EmptyView()
        case .continueToModel, .wake: button(verbatim: words("firstrun.wake", flow.impName)) { flow.wakeUp() }
        case .loading: button(verbatim: words("firstrun.wake", flow.impName)) {}.disabled(true)
        case .tryAgain: button("common.try_again") { flow.wakeUp() }
        case .waking: button(verbatim: words("firstrun.check.running", flow.impName)) {}.disabled(true)
        }
    }

    private func button(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.primary).keyboardShortcut(.defaultAction)
    }

    /// For text that is already final (formatted at runtime), shown as it is.
    private func button(verbatim title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(verbatim: title) }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
    }
}
