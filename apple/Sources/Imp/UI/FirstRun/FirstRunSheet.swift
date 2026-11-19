import ImpDesign
import ImpKit
import SwiftUI

/// The first run on the Mac: a sheet over the window with the Imp (asleep, stirring, awake) on top, the one
/// page below (`FirstRunFlow`) and, at the bottom, Cancel and the primary button. The top bar has Close, which
/// does the same as Cancel: the Imp stays asleep, a calm state of its own.
struct FirstRunSheet: View {
    @Bindable var flow: FirstRunModel
    let hue: Double
    let traits: ImpTraits
    let clock: BodyClock
    /// Close, or the end: the sheet goes away.
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { flow.impName }

    var body: some View {
        SheetFrame(width: Sizing.sheetWidth, cancel: close) {
            header
        } content: {
            FirstRunFlow(flow: flow)
        } footer: {
            FirstRunPrimaryButton(flow: flow)
        }
        .impAnimation(ImpDesign.Motion.scene, value: flow.path.imp)
        .onChange(of: flow.path.step) { _, step in if step == .done { close() } }
    }

    // MARK: The bar and the Imp

    private var header: some View {
        VStack(spacing: Spacing.small) {
            SheetBar(close: close)
                .sheetBarInsets()
            StageImp(hue: hue, mood: mood, traits: traits, clock: clock)
                .environment(\.stageAwake, !(flow.path.imp == .asleep && reduceMotion))
                .frame(width: Sizing.heroImp, height: Sizing.heroImp)
                .accessibilityElement()
                .accessibilityLabel(flow.path.imp == .asleep ? words("brain.zzz", name) : name)
            Text(verbatim: bubble).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.page)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.small)
    }

    private var mood: Mood {
        switch flow.path.imp {
        case .asleep: .sleepy
        case .stirring: .thinking
        case .awake: .happy
        }
    }

    /// What the Imp says at this moment.
    private var bubble: String {
        switch flow.path.step {
        case .service, .loadingModels, .model, .failed: words("firstrun.asleep_bubble", name)
        case .checking: words("firstrun.check.running", name)
        case .awake, .done: words("firstrun.check.ok", name)
        }
    }
}
