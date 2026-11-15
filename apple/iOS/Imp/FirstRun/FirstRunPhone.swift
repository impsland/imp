import ImpDesign
import ImpKit
import SwiftUI

/// The first run on the iPhone: waking an Imp that has no Brain, on one screen (`PhoneBrainForm`). The same
/// words as on the Mac, in this app's controls. A local preset is a server on another computer: the user edits its address.
/// Close leaves the Imp asleep.
struct FirstRunPhone: View {
    let pocket: PocketRuntime
    let id: UUID
    /// Close: the sheet goes away and the Imp stays asleep.
    let close: () -> Void
    /// The end: the Imp is awake and its chat comes up.
    let awake: () -> Void
    @State private var flow: FirstRunModel

    init(pocket: PocketRuntime, id: UUID, close: @escaping () -> Void, awake: @escaping () -> Void) {
        self.pocket = pocket
        self.id = id
        self.close = close
        self.awake = awake
        let imp = pocket.imp(id)
        let services = FirstRunServices.live(persona: pocket.personality(of: id), probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        _flow = State(initialValue: FirstRunModel(impName: imp?.name ?? "", onThisComputer: false, services: services,
                                                  preselectsModel: false) { [weak pocket] brain in
            try pocket?.adoptFirstRunBrain(brain, for: id)
        })
    }

    var body: some View {
        FirstRunPhoneSheet(flow: flow, imp: pocket.imp(id), close: close, awake: awake)
    }
}

/// The sheet: the bar, the Imp waking up, the form and the one button in the thumb zone. It has nothing behind it
/// but a `FirstRunModel`, so each step can be previewed.
struct FirstRunPhoneSheet: View {
    @Bindable var flow: FirstRunModel
    let imp: LinkImp?
    let close: () -> Void
    let awake: () -> Void

    private var name: String { flow.impName }

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(close: close) {
                Text("brain.title").font(Typeface.cardTitle).foregroundStyle(Tone.text).accessibilityAddTraits(.isHeader)
            }
            .sheetBarInsets()
            // The hero is sized by the page without the keyboard, so the keyboard coming up only lifts Continue.
            FormPage { page in
                VStack(spacing: Spacing.large) {
                    hero(height: page.height)
                    PhoneBrainForm(flow: flow)
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.medium).padding(.bottom, Spacing.medium)
            } footer: {
                PhoneBrainButton(flow: flow)
                    .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.medium).padding(.top, Spacing.small)
            }
        }
        // Waking an Imp is that Imp's sheet: it wears its colour.
        .impControls(tint: imp.map { Color.imp($0.hue) } ?? Tone.accent)
        .background(Tone.surface)
        .onChange(of: flow.path.step) { _, step in if step == .done { awake() } }
    }

    /// The Imp, as big as the room allows (a quarter of the height), and what it says.
    private func hero(height: CGFloat) -> some View {
        let side = min(max(height * 0.25, Sizing.marker * 1.5), Sizing.marker * 3)
        return VStack(spacing: Spacing.small) {
            Group {
                if let imp { LiveImp(imp: imp, mood: mood) }
            }
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel(flow.path.imp == .asleep ? words("brain.zzz", name) : name)
            Text(verbatim: bubble).font(Typeface.body).foregroundStyle(Tone.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var mood: Mood {
        switch flow.path.imp {
        case .asleep: .sleepy
        case .stirring: .thinking
        case .awake: .happy
        }
    }

    /// What the Imp says at this step.
    private var bubble: String {
        switch flow.path.step {
        case .service, .loadingModels, .model, .failed: words("firstrun.asleep_bubble", name)
        case .checking: words("firstrun.check.running", name)
        case .awake, .done: words("firstrun.check.ok", name)
        }
    }
}

// MARK: - Previews

@MainActor private func previewFlow(_ events: (FirstRunModel) -> Void = { _ in }) -> FirstRunModel {
    let services = FirstRunServices(find: { [] }, models: { _, _ in [] }, check: { _ in })
    let flow = FirstRunModel(impName: "Dot", onThisComputer: false, services: services) { _ in }
    events(flow)
    return flow
}

private let previewImp = LinkImp(id: UUID(), name: "Dot", hue: ImpProfile.defaultHue, scale: 1, traits: .plain)

@MainActor private func page(_ flow: FirstRunModel) -> some View {
    FirstRunPhoneSheet(flow: flow, imp: previewImp, close: {}, awake: {})
}

#Preview("Service") { page(previewFlow()) }
#Preview("A server on the network") { page(previewFlow { if let local = ServicePreset.local { $0.choose(local) } }) }
#Preview("Empty key") { page(previewFlow { $0.wakeUp() }) }
