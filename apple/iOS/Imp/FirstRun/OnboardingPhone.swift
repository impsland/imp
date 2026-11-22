import ImpDesign
import ImpKit
import SwiftUI

/// The first run on the iPhone: three steps, the picture and title of the step on top, what it says below, and Next
/// in the thumb zone. Nothing asks for anything: Next is the only thing to press. Close leaves with no Imp made.
struct OnboardingPhone: View {
    let pocket: PocketRuntime
    let close: () -> Void
    /// The end: the Imp exists, with the prompt sent, and its chat comes up.
    let finished: (UUID) -> Void
    private let id: UUID
    @State private var flow: OnboardingModel

    init(pocket: PocketRuntime, id: UUID, close: @escaping () -> Void, finished: @escaping (UUID) -> Void) {
        self.pocket = pocket
        self.id = id
        self.close = close
        self.finished = finished
        _flow = State(initialValue: OnboardingPhoneHost.model(pocket: pocket, id: id))
    }

    var body: some View {
        OnboardingPhoneSheet(flow: flow, imp: LinkImp(id: id, name: flow.impName, hue: ImpProfile.defaultHue, scale: 1, traits: .plain), close: close)
            .task { flow.begin() }
            .onChange(of: flow.isOver) { _, over in if over { finished(id) } }
            .onDisappear { flow.cancel() }
    }
}

/// The sheet, with nothing behind it but an `OnboardingModel`, so each step can be built without the app.
struct OnboardingPhoneSheet: View {
    @Bindable var flow: OnboardingModel
    let imp: LinkImp
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(back: flow.canGoBack ? { flow.back() } : nil, close: close) {
                Text(words("onboarding.step.of", String(flow.step.rawValue), String(OnboardingStep.allCases.count)))
                    .font(Typeface.small).foregroundStyle(Tone.muted)
            }
            .sheetBarInsets()
            FormPage { _ in
                VStack(spacing: Spacing.large) {
                    picture.frame(height: OnboardingPicture.height).accessibilityHidden(true)
                    Text(title).font(Typeface.cardTitle).foregroundStyle(Tone.text).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboarding.title")
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.medium).padding(.bottom, Spacing.medium)
            } footer: {
                Button("onboarding.next") { flow.next() }
                    .buttonStyle(WideButtonStyle()).disabled(!flow.nextEnabled).accessibilityIdentifier("onboarding.next")
                    .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.medium).padding(.top, Spacing.small)
            }
        }
        .impControls(tint: Color.imp(imp.hue))
        .background(Tone.surface)
        .impAnimation(ImpDesign.Motion.scene, value: flow.step)
    }

    private var title: LocalizedStringKey {
        switch flow.step {
        case .model: "onboarding.step.model"
        case .move: "onboarding.step.move"
        case .setup: "onboarding.step.setup"
        }
    }

    private func figure(_ mood: Mood) -> some View { LiveImp(imp: imp, mood: mood) }

    @ViewBuilder private var picture: some View {
        switch flow.step {
        case .model: KeyPicture(host: flow.issuer?.settings.host ?? "", connected: flow.brain != nil, hue: imp.hue, figure: figure)
        case .move: MovePicture(fromPhone: true, figure: figure)
        case .setup: SetupPicture(prompt: flow.prompt, figure: figure)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .model: ModelStep(flow: flow)
        case .move: Text("onboarding.move.body").font(Typeface.body).foregroundStyle(Tone.text)
        case .setup:
            Text("onboarding.setup.body").font(Typeface.body).foregroundStyle(Tone.text)
            PhonePromptEditor(text: $flow.prompt)
            if let problem = flow.problem { StatusText(verbatim: problem, symbol: "exclamationmark.circle", color: Tone.warnText) }
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
            PhoneBrainForm(flow: flow.form)
            if flow.isReseller {
                Button("onboarding.use_included") { flow.useIncludedModel() }.buttonStyle(.plain).font(Typeface.label).foregroundStyle(Tone.accent)
            }
        } else if let issuer = flow.issuer {
            IssuerStatus(issuer: issuer)
            if issuer.state == .issued {
                Button("onboarding.change_connection") { flow.changeConnection() }
                    .buttonStyle(.plain).font(Typeface.label).foregroundStyle(Tone.accent).accessibilityIdentifier("onboarding.change")
            }
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
                ProgressView()
                Text("onboarding.model.issuing").font(Typeface.body).foregroundStyle(Tone.text)
            }
        case .issued:
            Label { Text(words("onboarding.model.ready", issuer.settings.host)) } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(Typeface.body).foregroundStyle(Tone.text)
        case .failed(let retryable, let wait):
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("onboarding.retry.title").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                Text(retryable ? "onboarding.retry.body" : "onboarding.retry.final").font(Typeface.body).foregroundStyle(Tone.muted)
                if let wait, !issuer.canRetry { Text(words("onboarding.retry.wait", String(wait))).font(Typeface.caption).foregroundStyle(Tone.muted) }
                if retryable { Button("common.try_again") { issuer.retry() }.buttonStyle(WideButtonStyle()) }
                if let detail = issuer.detail, !detail.isEmpty {
                    DisclosureGroup("onboarding.retry.details", isExpanded: $detailsOpen) {
                        Text(verbatim: detail).font(Typeface.caption).foregroundStyle(Tone.muted).textSelection(.enabled)
                    }
                    .font(Typeface.caption)
                }
            }
        }
    }
}

/// The prompt, editable, in a field that grows with it.
struct PhonePromptEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Typeface.body)
            .scrollContentBackground(.hidden)
            .padding(Spacing.cozy)
            .frame(minHeight: Sizing.control * 3)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityLabel(Text("onboarding.prompt.field"))
            .accessibilityIdentifier("onboarding.prompt")
    }
}

/// The setup prompt of an Imp, from its Brain settings: change it, restore it, or send it again.
struct PhoneSetupPromptSheet: View {
    let pocket: PocketRuntime
    let id: UUID
    let close: () -> Void
    @State private var text = OnboardingPrompt.preset

    private var words: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(close: close) { Text("onboarding.setup_prompt").font(Typeface.cardTitle).foregroundStyle(Tone.text) }.sheetBarInsets()
            FormPage { _ in
                VStack(alignment: .leading, spacing: Spacing.large) {
                    PhonePromptEditor(text: $text)
                    Button("onboarding.prompt.reset") { text = OnboardingPrompt.preset }.buttonStyle(.plain).font(Typeface.label).foregroundStyle(Tone.accent)
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.medium)
            } footer: {
                Button("onboarding.prompt.send_again") { pocket.ask(id, words); close() }
                    .buttonStyle(WideButtonStyle()).disabled(words.isEmpty || !pocket.hasBrain(id))
                    .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.medium)
            }
        }
        .background(Tone.surface)
    }
}
