import ImpDesign
import ImpKit
import SwiftUI

/// Hatches an Imp on this iPhone, or changes one. One sheet: the bar on top, the live Imp under it (it shrinks
/// when a panel is open but never goes away) and then the hub of settings or the open panel. Back in a panel
/// returns to the hub, Close dismisses. The one button (Hatch or Save) is at the bottom of the hub. Keys are typed
/// once and go to the Keychain. With accessibility text sizes or VoiceOver the hub is a plain list.
struct PocketEditor: View {
    let pocket: PocketRuntime
    /// The Imp being changed, or nil for a new one.
    let editing: UUID?
    var done: () -> Void

    @State private var draft: PocketDraft
    @State private var open: ImpSetting?
    /// The guided Brain setup, while the Imp has none or its Brain is being changed.
    @State private var brainFlow: FirstRunModel?
    @State private var voiceOver = UIAccessibility.isVoiceOverRunning
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saveProblem: String?
    @State private var confirmingGoodbye = false
    @State private var removing: UUID?

    init(pocket: PocketRuntime, editing: UUID?, opening: ImpSetting? = nil, done: @escaping () -> Void) {
        self.pocket = pocket
        self.editing = editing
        self.done = done
        let draft = PocketDraft(pocket: pocket, editing: editing)
        _draft = State(initialValue: draft)
        _open = State(initialValue: opening)
    }

    private var callName: String { draft.name.trimmed.isEmpty ? String(localized: "imp_settings.this_imp") : draft.name.trimmed }

    /// The plain list: with accessibility text sizes or a screen reader. A phone is always narrow, so only these decide.
    private var listed: Bool {
        ImpSettingsLayout.mode(width: CGFloat(Behavior.narrowWindowPoints), largeText: typeSize.isAccessibilitySize, screenReader: voiceOver) == .list
    }

    /// No Brain: the Imp sleeps, unless it is being woken right now. Calm, not a fault.
    private var asleep: Bool { !draft.hasBrain && brainFlow?.path.imp != .stirring }

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(back: open == nil ? nil : { leave() }, close: done) {
                Text(open.map { String(localized: $0.title) } ?? draft.name.trimmed)
                    .font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            } leading: {
                // Goodbye is an action on the whole Imp, not a setting: an icon in the corner Back leaves free.
                if editing != nil {
                    HoverIconButton(systemName: "hand.wave.fill", help: "imp_settings.goodbye", tint: Tone.muted) { confirmingGoodbye = true }
                        .accessibilityLabel(words("imp_settings.goodbye.a11y", callName))
                }
            }
            .sheetBarInsets()
            if let open { panel(open) } else { hub }
        }
        // An Imp's settings wear its colour, live as it is being chosen.
        .impControls(tint: Color.imp(draft.hue))
        .background(Tone.surface)
        .presentationBackground(Tone.surface)
        .confirmationDialog(words("goodbye.title", callName), isPresented: $confirmingGoodbye, titleVisibility: .visible) {
            Button("goodbye.confirm", role: .destructive) {
                if let editing { pocket.delete(editing) }
                done()
            }
            Button(words("goodbye.cancel", callName), role: .cancel) {}
        } message: {
            Text("goodbye.message")
        }
        .confirmationDialog("tools.remove_server", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("common.remove", role: .destructive) {
                withImpAnimation(reduceMotion: reduceMotion) { draft.servers.removeAll { $0.id == removing } }
                removing = nil
            }
        } message: {
            Text("tools.remove_server.message")
        }
        .alert("phone.editor.save_failed_title", isPresented: Binding(get: { saveProblem != nil }, set: { if !$0 { saveProblem = nil } })) {
            Button("common.done", role: .cancel) {}
        } message: {
            Text(saveProblem ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)) { _ in
            voiceOver = UIAccessibility.isVoiceOverRunning
        }
        .onAppear { if open == .brain, !draft.hasBrain, brainFlow == nil { startFlow(open: false) } }
        // The guided setup is over once the Imp is awake: the panel then shows the Brain it ended with.
        .onChange(of: brainFlow?.path.step) { _, step in
            if step == .done { brainFlow = nil }
        }
    }

    // MARK: Hub

    /// The one button (Hatch or Save) stands under the hub, above the keyboard while the name is typed.
    private var hub: some View {
        FormPage { page in
            if listed { listHub } else { markerHub(page) }
        } footer: {
            Button(draft.isNew ? "phone.editor.hatch" : "phone.editor.save", action: save)
                .buttonStyle(WideButtonStyle())
                .disabled(!draft.canSave)
                .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.medium)
        }
    }

    /// The Imp with its four markers on an even arrangement, then its name. Centred in the room there is
    /// without the keyboard, so the keyboard coming up only scrolls it.
    private func markerHub(_ page: CGSize) -> some View {
        let imp = ImpSettingsGeometry.phoneImp(width: page.width)
        let stage = ImpSettingsGeometry.phoneStageHeight(imp: imp)
        return VStack(spacing: Spacing.large) {
            ZStack {
                preview.frame(width: imp, height: imp)
                ForEach(PocketDraft.settings) { setting in
                    if let slot = ImpSettingsGeometry.phoneSlot(setting) {
                        PhoneMarker(setting: setting, value: value(setting), lit: lit(setting),
                                    asleepNote: words("imp_settings.brain_marker.asleep", callName)) { pick(setting) }
                            .offset(ImpSettingsGeometry.phoneOffset(slot, imp: imp))
                    }
                }
            }
            .frame(width: page.width, height: stage)
            nameField.padding(.horizontal, Spacing.page)
        }
        .frame(maxWidth: .infinity, minHeight: page.height)
    }

    private var listHub: some View {
        VStack(spacing: Spacing.medium) {
            preview.frame(width: ImpSettingsGeometry.listImp, height: ImpSettingsGeometry.listImp)
                .accessibilityHidden(true)
            nameField
            VStack(spacing: 0) {
                ForEach(ImpSetting.listOrder.filter(PocketDraft.settings.contains)) { setting in
                    PhoneListRow(setting: setting, value: value(setting), lit: lit(setting),
                                 asleepNote: words("imp_settings.brain_marker.asleep", callName)) { pick(setting) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(words("imp_settings.list.label", callName))
        }
        .padding(.horizontal, Spacing.page)
    }

    /// The Imp's name as the title-like field under it.
    private var nameField: some View {
        VStack(spacing: Spacing.tight) {
            TextField("personality.name", text: $draft.name)
                .impField()
                .font(Typeface.cardTitle)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
            if let problem = draft.nameProblem { IssueBadge(text: problem) }
            else if draft.name.trimmed.isEmpty { IssueBadge(text: String(localized: "personality.name_empty")) }
        }
    }

    private func lit(_ setting: ImpSetting) -> Bool { setting != .brain || draft.hasBrain }

    /// A count or a state word, never a sentence.
    private func value(_ setting: ImpSetting) -> String? {
        switch setting {
        case .brain: return draft.hasBrain ? nil : String(localized: "imp_settings.value.asleep")
        case .tools:
            let real = draft.servers.filter { !$0.isBlank }
            if real.isEmpty { return nil }
            return words("imp_settings.value.tools", real.filter { draft.serverProblem($0) == nil }.count, real.count)
        case .personality, .look, .triggers, .moves: return nil
        }
    }

    /// The Imp, asleep with Zzz. It leans the way the phone tips, as on the first screen.
    private var preview: some View {
        TiltImp(imp: LinkImp(id: draft.id, name: draft.name, hue: draft.hue, scale: 1, traits: draft.traits), interactive: false)
            .scaleEffect(ImpSettingsGeometry.previewScale(draft.scale))
            .impAnimation(ImpDesign.Motion.smooth, value: draft.scale)
            .overlay(alignment: .topTrailing) {
                if asleep {
                    Text(verbatim: "Zzz").font(Typeface.cardTitle).foregroundStyle(Tone.muted).accessibilityHidden(true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(asleep ? words("brain.zzz", callName) : callName)
    }

    // MARK: Panels

    private func panel(_ setting: ImpSetting) -> some View {
        VStack(spacing: 0) {
            preview.frame(width: ImpSettingsGeometry.listImp * 0.7, height: ImpSettingsGeometry.listImp * 0.7)
                .padding(.vertical, Spacing.small)
            ScrollViewReader { proxy in
                // The Brain's Continue stands under the panel, above the keyboard while an address or a key is typed.
                FormPage { _ in
                    Group {
                        switch setting {
                        case .brain: PocketBrainPanel(draft: draft, flow: brainFlow, change: { startFlow() })
                        case .personality: PocketPersonalityPanel(draft: draft)
                        case .look: PocketLookPanel(draft: draft)
                        case .tools: PocketToolsPanel(draft: draft, proxy: proxy, removing: $removing)
                        case .triggers, .moves: EmptyView()
                        }
                    }
                    .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } footer: {
                    if setting == .brain, let brainFlow {
                        FirstRunPhoneButton(flow: brainFlow)
                            .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.medium)
                    }
                }
            }
        }
    }

    /// A marker opens its panel in place of the hub. An Imp without a Brain meets the guided setup there.
    private func pick(_ setting: ImpSetting) {
        if setting == .brain, !draft.hasBrain, brainFlow == nil { startFlow(open: false) }
        withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { open = setting }
    }

    private func leave() {
        withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { open = nil }
    }

    /// The first-run steps for this Imp, with what it has now filled in.
    private func startFlow(open: Bool = true) {
        let services = FirstRunServices.live(persona: draft.personality.trimmed.isEmpty ? Persona.pocket(named: draft.name.trimmed) : draft.personality,
                                             probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        let flow = FirstRunModel(impName: callName, onThisComputer: false, services: services) { [draft, pocket, editing] brain in
            // An Imp that already lives here keeps its Brain the moment it wakes, whatever happens to the
            // rest of the sheet. A new one keeps it when it is hatched.
            if let editing { try pocket.adoptFirstRunBrain(brain, for: editing) }
            draft.adopt(brain)
        }
        if draft.hasBrain {
            if let service = draft.service ?? (ServicePreset.isOwnComputer(draft.brain.baseURL) ? ServicePreset.local : ServicePreset.remote) {
                flow.choose(service)
            }
            flow.address = draft.brain.baseURL
            flow.model = draft.brain.model
            flow.key = pocket.secrets.get(.apiKey, imp: draft.id) ?? ""
        }
        brainFlow = flow
    }

    private func save() {
        do {
            try draft.save(into: pocket)
            done()
        } catch {
            saveProblem = error.localizedDescription
        }
    }
}
