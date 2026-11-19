import ImpDesign
import ImpKit
import SwiftUI

/// The first run on one page, without any modal chrome, so the sheet and the Brain panel of an Imp show the
/// very same content: the choice (Remote or Local), the address, the key and the model (left blank, the first
/// one that chats is used), then what went wrong in a line of its own that is always there, as on the iPhone.
/// Put `FirstRunPrimaryButton` under it. Nothing here moves when something goes wrong: the problem line
/// keeps its height and the button says what is happening. The flow is over when `flow.path.step == .done`:
/// the Imp is awake.
struct FirstRunFlow: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.roomy) {
            fields
            StatusSlot(flow.problemText, symbol: "exclamationmark.circle", color: Tone.warnText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fields: some View {
        ServiceFields(choice: flow.choice, found: { flow.running($0) != nil }, pick: { flow.choose($0) },
                      address: $flow.address, key: $flow.key, showsKey: flow.showsKey,
                      submit: { flow.wakeUp() }) {
            FieldRow("brain.model", info: "settings.service.model.info") {
                ModelField(model: $flow.model, placeholder: "firstrun.model.search") { [address = flow.address, key = flow.key] in
                    try await OpenAIClient(baseURL: address.trimmingCharacters(in: .whitespacesAndNewlines),
                                           apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
                        .models(timeout: Double(Behavior.modelListTimeoutSeconds))
                }
                .disabled(!ServicePreset.isValidAddress(flow.address))
            }
        }
        .disabled(flow.path.isBusy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { flow.discover() }
    }
}

/// The one primary button of the first run: Wake {name} up, or Try again after a failure. Return presses it.
/// In a sheet's footer it is the standard pill, the size of Cancel beside it (`wide: false`). In the Brain panel it
/// is as wide as the page, as on the iPhone. Its width is the widest of its words, so it never changes size as the
/// Imp stirs or an error shows.
struct FirstRunPrimaryButton: View {
    @Bindable var flow: FirstRunModel
    var wide = true

    var body: some View {
        switch flow.primary {
        case .none: EmptyView()
        case .continueToModel, .wake: button(wake) { flow.wakeUp() }
        case .loading: button(wake) {}.disabled(true)
        case .tryAgain: button(String(localized: "common.try_again")) { flow.wakeUp() }
        case .waking: button(waking) {}.disabled(true)
        }
    }

    private var wake: String { words("firstrun.wake", flow.impName) }
    private var waking: String { words("firstrun.check.running", flow.impName) }

    /// The text is already final (formatted at runtime), shown as it is.
    @ViewBuilder private func button(_ title: String, action: @escaping () -> Void) -> some View {
        if wide {
            Button(action: action) { Text(verbatim: title) }.buttonStyle(WideButtonStyle()).keyboardShortcut(.defaultAction)
        } else {
            Button(action: action) {
                ZStack {
                    // Every wording takes room, only the current one shows: the button keeps its size.
                    ForEach([wake, waking, String(localized: "common.try_again")], id: \.self) { Text(verbatim: $0).hidden() }
                    Text(verbatim: title)
                }
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
    }
}
