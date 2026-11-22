import ImpDesign
import ImpKit
import SwiftUI

/// Two ways back into the first run from an Imp's Brain panel: change the connection (address, key, model), and
/// open the setup prompt to change it or send it to the Imp again.
struct ConnectionActions: View {
    let model: AppModel
    let imp: UUID
    @State private var changing = false
    @State private var prompting = false

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Button("onboarding.change_connection") { changing = true }.buttonStyle(.secondary)
            Button("onboarding.setup_prompt") { prompting = true }.buttonStyle(.secondary)
        }
        .sheet(isPresented: $changing) { ConnectionSheet(model: model, imp: imp) { changing = false } }
        .sheet(isPresented: $prompting) { SetupPromptSheet(model: model, imp: imp) { prompting = false } }
    }
}

/// The form for an address, a key and a model, with its check.
private struct ConnectionSheet: View {
    let model: AppModel
    @State private var flow: FirstRunModel
    let close: () -> Void

    init(model: AppModel, imp: UUID, close: @escaping () -> Void) {
        self.model = model
        self.close = close
        _flow = State(initialValue: OnboardingHost.connectionForm(app: model, imp: imp))
    }

    var body: some View {
        SheetFrame(width: Sizing.sheetWidth, cancel: close) {
            Text("onboarding.change_connection").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                .frame(maxWidth: .infinity).padding(.top, Spacing.page)
        } content: {
            FirstRunFlow(flow: flow)
        } footer: {
            FirstRunPrimaryButton(flow: flow, wide: false)
        }
        .onChange(of: flow.path.step) { _, step in if step == .done { close() } }
        .onDisappear { flow.cancel() }
    }
}

/// The setup prompt of an Imp: change it, restore it, or send it again.
private struct SetupPromptSheet: View {
    let model: AppModel
    let imp: UUID
    let close: () -> Void
    @State private var text = OnboardingPrompt.preset

    var body: some View {
        SheetFrame(width: Sizing.sheetWidth, cancel: close) {
            Text("onboarding.setup_prompt").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                .frame(maxWidth: .infinity).padding(.top, Spacing.page)
        } content: {
            PromptEditor(text: $text)
            Button("onboarding.prompt.reset") { text = OnboardingPrompt.preset }.buttonStyle(.quiet)
        } footer: {
            Button("onboarding.prompt.send_again") {
                model.send(setup: text.trimmingCharacters(in: .whitespacesAndNewlines), to: imp)
                close()
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isReady(imp))
        }
    }
}
