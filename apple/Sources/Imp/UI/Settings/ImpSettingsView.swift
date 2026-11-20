import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// One Imp's settings, laid out like the app's Settings: the bar, the rail of sections on the leading
/// side and the page of the chosen one beside it. A section is one click away from any other. Back (and
/// Esc) goes home, always. The bar's trailing actions are Share (saves the Imp as a kit file at once),
/// Goodbye (asks first) and the app's Settings.
struct ImpSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let id: UUID
    @State private var section: ImpSetting
    /// Set while the goodbye question is open.
    @State private var asking: [UUID]?

    init(model: AppModel, router: HomeRouter, id: UUID, open: ImpSetting? = nil) {
        self.model = model
        self.router = router
        self.id = id
        _section = State(initialValue: open ?? router.impSection)
    }

    /// Edits this Imp's profile in place.
    private var imp: Binding<ImpProfile> {
        Binding(get: { model.profile(id) ?? .imp },
                set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i] = new } })
    }

    /// No Brain: the Imp sleeps. Calm, not a fault, but the Brain section carries a mark.
    private var asleep: Bool { !model.isReady(id) }

    var body: some View {
        let profile = imp.wrappedValue
        VStack(spacing: 0) {
            bar(profile)
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    rail(profile, compact: proxy.size.width < CGFloat(Behavior.narrowWindowPoints))
                    ZStack {
                        SettingsPage { page }
                            .id(section)
                            .transition(.opacity)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(section.title))
                    }
                    .impAnimation(ImpDesign.Motion.scene, value: section)
                    .environment(\.highlightedSetting, router.highlightedSetting)
                }
            }
        }
        .environment(\.impTint, Color.imp(profile.hue))
        .tint(Color.imp(profile.hue))
        // A tool or a link can ask for one section, also while this page is already showing.
        .onChange(of: router.impPanel, initial: true) { _, wanted in
            guard let wanted else { return }
            router.impPanel = nil
            section = wanted
        }
        .onChange(of: section) { _, chosen in router.impSection = chosen }
        .goodbyeQuestion($asking, names: [profile.callName]) { ids in
            HomeActions(model: model, router: router).sayGoodbye(ids)
            router.goHome()
        }
    }

    /// Back, the Imp's name, then Share, Goodbye and Settings as icon buttons.
    private func bar(_ profile: ImpProfile) -> some View {
        TopBar(back: { router.goHome() }) {
            Text(verbatim: profile.callName)
                .font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        } trailing: {
            HStack(spacing: Spacing.small) {
                HoverIconButton(systemName: "square.and.arrow.up", help: "imp_settings.share") {
                    ImpExport.save([id], model: model, name: profile.callName, fileName: profile.callName)
                }
                .accessibilityLabel(words("imp_settings.share.a11y", profile.callName))
                HoverIconButton(systemName: "hand.wave.fill", help: "imp_settings.goodbye", tint: Tone.danger) { asking = [id] }
                    .accessibilityLabel(words("imp_settings.goodbye.a11y", profile.callName))
                HoverIconButton(systemName: "gearshape", help: "settings.title") { router.openGeneralSettings() }
            }
        }
    }

    private func rail(_ profile: ImpProfile, compact: Bool) -> some View {
        let items = ImpSetting.allCases.map { item in
            SectionItem(id: item, title: String(localized: item.title),
                        symbol: item == .brain && asleep ? "lightbulb" : item.symbol,
                        needsAttention: item == .brain && asleep)
        }
        return ScrollView(.vertical, showsIndicators: false) {
            SectionRail(LocalizedStringKey(words("imp_settings.list.label", profile.callName)), items: items,
                        selection: $section, axis: .vertical, compact: compact)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, Spacing.medium)
                .padding(.top, Spacing.hairline)
                .padding(.bottom, Spacing.page)
        }
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .brain: BrainPanel(model: model, imp: imp)
        case .personality: PersonalityPanel(model: model, imp: imp)
        case .look: LookPanel(model: model, imp: imp)
        case .animations: AnimationsPanel(model: model, imp: imp)
        case .triggers: TriggersPanel(model: model, imp: imp)
        case .tools:
            ToolsPanel(model: model, imp: imp)
            LibraryPanel(model: model)
        case .computer: ComputerPanel(model: model, imp: imp)
        }
    }
}

/// The real Imp, as the Look section's preview. Asleep it shows Zzz and holds still when Reduce Motion is on.
struct SettingsImp: View {
    let model: AppModel
    let profile: ImpProfile
    let asleep: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageImp(hue: profile.hue, mood: asleep ? .sleepy : .idle, performance: model.performances[profile.id],
                 traits: profile.traits, clock: BodyClock(profile.id))
            .environment(\.stageAwake, !(asleep && reduceMotion))
            .scaleEffect(Self.previewScale(profile.scale))
            .impAnimation(ImpDesign.Motion.smooth, value: profile.scale)
            .accessibilityElement()
            .accessibilityLabel(asleep ? words("brain.zzz", profile.callName) : profile.callName)
    }

    /// How much of the preview's frame the Imp fills for a size setting (0.75 to 1.7), so the size
    /// slider shows on the preview.
    static func previewScale(_ size: Double) -> Double {
        let t = (min(max(size, 0.75), 1.7) - 0.75) / (1.7 - 0.75)
        return 0.6 + 0.4 * t
    }
}

/// The face of an Imp in its colour, for still portraits.
func impFace(hue: Double, mood: Mood = .idle) -> Face {
    var f = Face.settled(mood)
    f.hue = hue
    return f
}
