import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// One Imp's settings. One bar heads the window and never moves: Back, the Imp's name (with the open
/// panel's name after it) and the Imp's actions. Under it the Imp stands large in the middle and its
/// settings sit around it as markers: the Brain above its head, then Look, Personality, Tools, Triggers
/// and Moves. A marker opens its panel beside the Imp. In a narrow window, with accessibility text sizes
/// or with VoiceOver, the same things are a plain list under the Imp and a panel takes the list's place.
/// The panel has no header of its own in either layout.
struct ImpSettingsView: View {
    @Bindable var model: AppModel
    @Bindable var router: HomeRouter
    let id: UUID
    @State private var nav: ImpSettingsNavigation
    @FocusState private var focusedMarker: ImpSetting?
    @AccessibilityFocusState private var spokenMarker: ImpSetting?
    @State private var sharing = false
    @State private var confirming = false
    @State private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, router: HomeRouter, id: UUID, open: ImpSetting? = nil) {
        self.model = model
        self.router = router
        self.id = id
        _nav = State(initialValue: ImpSettingsNavigation(panel: open))
    }

    private var open: ImpSetting? { nav.panel }

    /// Edits this Imp's profile in place.
    private var imp: Binding<ImpProfile> {
        Binding(get: { model.profile(id) ?? .imp },
                set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i] = new } })
    }

    var body: some View {
        let profile = imp.wrappedValue
        VStack(spacing: 0) {
            bar(profile)
            content(profile)
        }
        .environment(\.impTint, Color.imp(profile.hue))
        .environment(\.highlightedSetting, router.highlightedSetting)
        // A tool or a link can ask for one panel, also while this page is already showing.
        .onChange(of: router.impPanel, initial: true) { _, panel in
            guard let panel else { return }
            router.impPanel = nil
            move { nav.open(panel) }
        }
        .tint(Color.imp(profile.hue))
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        }
        .sheet(isPresented: $sharing) { ShareImpSheet(model: model, id: id) }
        .confirmationDialog(words("goodbye.title", profile.callName), isPresented: $confirming, titleVisibility: .visible) {
            Button("goodbye.confirm", role: .destructive, action: sayGoodbye)
            Button(words("goodbye.cancel", profile.callName), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("goodbye.message")
        }
    }

    /// The stage and the open panel under the bar, sized from one state, so opening, closing and
    /// switching are a single motion.
    private func content(_ profile: ImpProfile) -> some View {
        GeometryReader { geo in
            let total = geo.size.width
            let mode = ImpSettingsLayout.mode(width: total, largeText: typeSize.isAccessibilitySize, screenReader: voiceOver)
            let arrangement = ImpSettingsLayout.arrangement(width: total, largeText: typeSize.isAccessibilitySize,
                                                            screenReader: voiceOver, panelOpen: open != nil)
            let covered = arrangement == .panelOnly
            ZStack(alignment: .topTrailing) {
                stage(profile, mode: mode)
                    .frame(width: ImpSettingsLayout.stageWidth(total: total, arrangement: arrangement), height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(covered ? 0 : 1)
                    .disabled(covered)
                    .accessibilityHidden(covered)
                    .transaction { if reduceMotion { $0.animation = nil } }
                if let open {
                    SettingsPanelFrame(setting: open) { panel(open) }
                    .frame(width: ImpSettingsLayout.panelWidth(total: total, arrangement: arrangement), height: geo.size.height)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(width: total, height: geo.size.height, alignment: .topLeading)
        }
    }

    // MARK: Stage

    /// The Imp with its markers, or the plain list.
    @ViewBuilder private func stage(_ profile: ImpProfile, mode: ImpSettingsLayout.Mode) -> some View {
        switch mode {
        case .markers: markers(profile)
        case .list: list(profile)
        }
    }

    /// The window's one bar, the same in every layout. Back on the left, the name in the middle with the
    /// open panel's name after it. Share and Goodbye are actions, not settings: icon buttons in the
    /// trailing corner with a gap between them, Goodbye at the very edge.
    private func bar(_ profile: ImpProfile) -> some View {
        TopBar(back: back, backHelp: open == nil ? "Back to the Imps (Esc)" : "common.back") {
            HStack(spacing: Spacing.snug) {
                Text(verbatim: profile.callName).foregroundStyle(Tone.text)
                if let open {
                    Text(open.title).foregroundStyle(Tone.muted)
                }
            }
            .font(Typeface.cardTitle).lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } trailing: {
            HStack(spacing: Spacing.huge) {
                HoverIconButton(systemName: "square.and.arrow.up", help: "imp_settings.share") { sharing = true }
                    .accessibilityLabel(words("imp_settings.share.a11y", profile.callName))
                HoverIconButton(systemName: "hand.wave.fill", help: "imp_settings.goodbye", tint: Tone.muted) { confirming = true }
                    .disabled(model.prefs.imps.count <= 1)
                    .accessibilityLabel(words("imp_settings.goodbye.a11y", profile.callName))
            }
        }
    }

    /// The one Back. In a panel it returns to the settings' main screen (stage restored, focus back on
    /// the marker that opened it) and never leaves. On the main screen it goes home. Esc is the same.
    private func back() {
        var next = nav
        switch next.back() {
        case .leave: router.goHome()
        case .closedPanel(let marker):
            move { nav = next }
            DispatchQueue.main.async { focusedMarker = marker; spokenMarker = marker }
        }
    }

    /// Every change of the open panel runs through here: one animation for the stage and the panel.
    private func move(_ change: () -> Void) {
        withImpAnimation(ImpDesign.Motion.spring, reduceMotion: reduceMotion, change)
    }

    private func sayGoodbye() {
        guard let next = model.sayGoodbye(id) else { return }
        router.select(next)
        router.goHome()
    }

    // MARK: Markers

    private func markers(_ profile: ImpProfile) -> some View {
        GeometryReader { stage in
            let side = ImpSettingsGeometry.imp(in: stage.size)
            ZStack {
                SettingsImp(model: model, profile: profile, asleep: asleep).frame(width: side, height: side)
                ForEach(ImpSetting.allCases) { setting in
                    SettingMarker(setting: setting, profile: profile, state: state(setting, profile), picked: open == setting) { toggle(setting) }
                        .focused($focusedMarker, equals: setting)
                        .accessibilityFocused($spokenMarker, equals: setting)
                        .frame(width: ImpSettingsGeometry.markerWidth)
                        .offset(ImpSettingsGeometry.offset(setting.place, imp: side))
                }
            }
            .frame(width: stage.size.width, height: stage.size.height)
        }
    }

    /// A marker opens its panel, the Brain's too: with no Brain the panel has the setup in place.
    private func toggle(_ setting: ImpSetting) {
        move { nav.toggle(setting) }
    }

    // MARK: List

    /// The plain list: the Imp small at the top, then every setting as a compact row in reading order.
    /// A row opens its panel in place of the list.
    private func list(_ profile: ImpProfile) -> some View {
        ScrollView {
            VStack(spacing: Spacing.medium) {
                SettingsImp(model: model, profile: profile, asleep: asleep)
                    .frame(width: ImpSettingsGeometry.listImp, height: ImpSettingsGeometry.listImp)
                    .accessibilityHidden(true)
                VStack(spacing: Spacing.snug) {
                    ForEach(ImpSetting.listOrder) { setting in
                        SettingListRow(setting: setting, profile: profile, state: state(setting, profile)) { toggle(setting) }
                            .focused($focusedMarker, equals: setting)
                            .accessibilityFocused($spokenMarker, equals: setting)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(words("imp_settings.list.label", profile.callName))
            }
            .padding(.horizontal, Spacing.page)
            .padding(.bottom, Spacing.page)
            .frame(maxWidth: Sizing.column)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .impControls()
    }

    // MARK: Panels

    @ViewBuilder private func panel(_ setting: ImpSetting) -> some View {
        switch setting {
        case .brain: BrainPanel(model: model, imp: imp)
        case .personality: PersonalityPanel(model: model, imp: imp)
        case .look: LookPanel(imp: imp)
        case .tools: ToolsPanel(model: model, imp: imp)
        case .triggers: TriggersPanel(model: model, id: id)
        case .moves: MovesPanel(model: model, id: id)
        }
    }

    // MARK: State

    /// No Brain: the Imp sleeps. Calm, not a fault.
    private var asleep: Bool { !model.isReady(id) }

    private func state(_ setting: ImpSetting, _ profile: ImpProfile) -> SettingState {
        switch setting {
        case .brain:
            if asleep {
                return SettingState(summary: String(localized: "imp_settings.summary.brain_none"),
                                    value: String(localized: "imp_settings.value.asleep"), lit: false)
            }
            let brain = profile.brain
            let modelName = model.prefs.ai.model(in: brain)
            return SettingState(summary: words("imp_settings.summary.brain_set", model.prefs.ai.service(in: brain)?.label ?? "", modelName),
                                value: modelName)
        case .personality: return SettingState(summary: String(localized: "imp_settings.summary.personality"))
        case .look: return SettingState(summary: String(localized: "imp_settings.summary.look"))
        case .tools:
            let groups = ToolGroups.own(for: profile) + ToolGroups.mcp(for: profile, servers: model.prefs.mcpServers, tools: model.mcpToolNames)
            let (on, total) = ToolGroups.summary(groups)
            return SettingState(summary: words("imp_settings.summary.tools", on, total), value: words("imp_settings.value.tools", on, total), badge: on)
        case .triggers:
            let count = model.prefs.triggers(for: id).count
            return SettingState(summary: words("imp_settings.summary.triggers", count), value: count.formatted(), badge: count)
        case .moves: return SettingState(summary: String(localized: "imp_settings.summary.moves"))
        }
    }
}

/// The real Imp, large. Asleep it shows Zzz and holds still when Reduce Motion is on.
struct SettingsImp: View {
    let model: AppModel
    let profile: ImpProfile
    let asleep: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StageImp(hue: profile.hue, mood: asleep ? .sleepy : .idle, performance: model.performances[profile.id],
                 traits: profile.traits, clock: BodyClock(profile.id))
            .environment(\.stageAwake, !(asleep && reduceMotion))
            .scaleEffect(ImpSettingsGeometry.previewScale(profile.scale))
            .impAnimation(ImpDesign.Motion.smooth, value: profile.scale)
            .accessibilityElement()
            .accessibilityLabel(asleep ? words("brain.zzz", profile.callName) : profile.callName)
    }
}

/// The face of an Imp in its colour, for still portraits.
func impFace(hue: Double, mood: Mood = .idle) -> Face {
    var f = Face.settled(mood)
    f.hue = hue
    return f
}
