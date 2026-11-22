import ImpDesign
import ImpKit
import SwiftUI

/// The first run on the Mac: a sheet with three steps. The title and the picture of the step on top, what the
/// step says below, and at the bottom Back and Next. Nothing here asks for anything: Next is the only thing to press.
/// `linkDevice` is the second way to begin, for a new Imp: bring one from another device.
struct OnboardingSheet: View {
    @Bindable var flow: OnboardingModel
    let hue: Double
    let traits: ImpTraits
    let clock: BodyClock
    var linkDevice: (() -> Void)?
    let close: () -> Void
    @State private var promptOpen = false

    var body: some View {
        SheetFrame(width: Sizing.sheetWidth, cancel: close) {
            VStack(spacing: Spacing.roomy) {
                SheetBar(close: close).sheetBarInsets()
                picture.frame(height: OnboardingPicture.height).accessibilityHidden(true)
                VStack(spacing: Spacing.small) {
                    Text(words("onboarding.step.of", String(flow.step.rawValue), String(OnboardingStep.allCases.count)))
                        .font(Typeface.small).foregroundStyle(Tone.muted)
                    Text(title).font(Typeface.cardTitle).foregroundStyle(Tone.text).multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.page)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.small)
        } content: {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if flow.canGoBack { Button("common.back") { flow.back() }.buttonStyle(.quiet) }
            if let linkDevice, flow.step == .model {
                Button(action: linkDevice) { Label("firstrun.link", systemImage: "iphone.and.arrow.forward") }
                    .buttonStyle(.quiet).help(Text("firstrun.link.help"))
            }
            Button("onboarding.next") { flow.next() }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!flow.nextEnabled)
        }
        .onChange(of: flow.isOver) { _, over in if over { close() } }
        .impAnimation(ImpDesign.Motion.scene, value: flow.step)
    }

    private var title: LocalizedStringKey {
        switch flow.step {
        case .model: "onboarding.step.model"
        case .move: "onboarding.step.move"
        case .setup: "onboarding.step.setup"
        }
    }

    private func figure(_ mood: Mood) -> some View {
        StageImp(hue: hue, mood: mood, traits: traits, clock: clock).environment(\.stageAwake, false)
    }

    @ViewBuilder private var picture: some View {
        switch flow.step {
        case .model: KeyPicture(host: flow.issuer?.settings.host ?? "", connected: flow.brain != nil, hue: hue, figure: figure)
        case .move: MovePicture(fromPhone: false, figure: figure)
        case .setup: SetupPicture(prompt: flow.prompt, figure: figure)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .model: ModelStep(flow: flow)
        case .move: Text("onboarding.move.body").font(Typeface.body).foregroundStyle(Tone.text)
        case .setup:
            Text("onboarding.setup.body").font(Typeface.body).foregroundStyle(Tone.text)
            PromptEditor(text: $flow.prompt)
            StatusSlot(flow.problem, symbol: "exclamationmark.circle", color: Tone.warnText)
        }
    }
}

/// Step 1: the model that came with the app (with its retry state), or the form for the user's own.
private struct ModelStep: View {
    @Bindable var flow: OnboardingModel

    var body: some View {
        Text("onboarding.model.body").font(Typeface.body).foregroundStyle(Tone.text)
        if flow.editingConnection {
            Text("onboarding.model.form").font(Typeface.body).foregroundStyle(Tone.text)
            FirstRunFlow(flow: flow.form)
            if flow.isReseller {
                Button("onboarding.use_included") { flow.useIncludedModel() }.buttonStyle(.quiet)
            }
        } else if let issuer = flow.issuer {
            IssuerStatus(issuer: issuer)
            if issuer.state == .issued { Button("onboarding.change_connection") { flow.changeConnection() }.buttonStyle(.quiet) }
        }
    }
}

/// What issuing the key looks like: working, connected, or a calm failure with Try again and the details tucked away.
private struct IssuerStatus: View {
    let issuer: KeyIssuer
    @State private var detailsOpen = false

    var body: some View {
        switch issuer.state {
        case .idle, .issuing:
            HStack(spacing: Spacing.cozy) {
                ProgressView().controlSize(.small)
                Text("onboarding.model.issuing").font(Typeface.body).foregroundStyle(Tone.text)
            }
        case .issued:
            Label { Text(words("onboarding.model.ready", issuer.settings.host)) } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(Typeface.body).foregroundStyle(Tone.text)
        case .failed(let retryable, let wait):
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("onboarding.retry.title").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                Text(retryable ? "onboarding.retry.body" : "onboarding.retry.final").font(Typeface.body).foregroundStyle(Tone.muted)
                if let wait, !issuer.canRetry { Text(words("onboarding.retry.wait", String(wait))).font(Typeface.small).foregroundStyle(Tone.muted) }
                if retryable { Button("common.try_again") { issuer.retry() }.buttonStyle(.secondary) }
                if let detail = issuer.detail, !detail.isEmpty {
                    DisclosureGroup("onboarding.retry.details", isExpanded: $detailsOpen) {
                        Text(verbatim: detail).font(Typeface.small).foregroundStyle(Tone.muted).textSelection(.enabled)
                    }
                    .font(Typeface.small)
                }
            }
        }
    }
}

/// The prompt, editable, in a field that grows with it.
struct PromptEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Typeface.body)
            .scrollContentBackground(.hidden)
            .padding(Spacing.cozy)
            .frame(minHeight: Sizing.control * 3)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityLabel(Text("onboarding.prompt.field"))
    }
}
