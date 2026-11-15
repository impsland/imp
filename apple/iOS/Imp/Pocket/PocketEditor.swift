import ImpDesign
import ImpKit
import SwiftUI

/// An Imp hatched on this iPhone, in its settings. One sheet: the bar on top, then the hub (the Imp, its name and
/// what it thinks with, and one list of its settings) or the open panel. Back in a panel returns to the hub, Close
/// dismisses. Every change is kept as it is made, as in the iPhone's own Settings: there is no Save, and Close
/// never loses anything. Keys go to the Keychain. A Brain that works is the end of the errand: the sheet closes by
/// itself, and an Imp that slept until then comes up in its chat, ready to talk.
struct PocketEditor: View {
    let pocket: PocketRuntime
    let id: UUID
    var done: () -> Void
    /// The Imp woke up here (it had no Brain before): its chat comes up.
    var woke: () -> Void
    /// The sheet rests at half height and the Imp itself waits in the room above it: it is the preview, so the
    /// sheet draws no second one.
    var roomInView = false

    @State private var draft: PocketDraft
    @State private var open: ImpSetting?
    /// The Brain form. Its button checks the Brain and keeps it.
    @State private var brainFlow: FirstRunModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saveProblem: String?
    @State private var confirmingGoodbye = false
    @State private var removing: UUID?
    @State private var saving: Task<Void, Never>?

    init(pocket: PocketRuntime, editing: UUID, opening: ImpSetting? = nil, roomInView: Bool = false,
         done: @escaping () -> Void, woke: @escaping () -> Void = {}) {
        self.pocket = pocket
        self.id = editing
        self.roomInView = roomInView
        self.done = done
        self.woke = woke
        _draft = State(initialValue: PocketDraft(pocket: pocket, editing: editing))
        _open = State(initialValue: opening)
    }

    private var callName: String { draft.name.trimmed.isEmpty ? String(localized: "imp_settings.this_imp") : draft.name.trimmed }

    /// No Brain: the Imp sleeps, unless it is being woken right now. Calm, not a fault.
    private var asleep: Bool { !draft.hasBrain && brainFlow?.path.imp != .stirring }

    var body: some View {
        VStack(spacing: 0) {
            // The hub's title is the Imp's name under its picture. A panel's is in the bar.
            SheetBar(back: open == nil ? nil : { leave() }, close: close) {
                if let open {
                    Text(open.title).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
            } leading: {
                EmptyView()
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
                saving?.cancel()
                pocket.delete(id)
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
        .onAppear {
            wokeHere = !draft.hasBrain
            if open == .brain { startFlow() }
        }
        // Kept as it changes, a moment after the last change: a name or a persona being typed is not saved letter by
        // letter, and a pick (a colour, a character, a size) shows on the Imp in the room almost at once.
        .onChange(of: draft.fingerprint) { old, new in
            let typing = old.first != new.first || old.dropFirst(4).first != new.dropFirst(4).first
            save(after: .milliseconds(typing ? 350 : 80))
        }
        // A Brain that works is kept by the form itself, and the errand is over: why stay?
        .onChange(of: brainFlow?.path.step) { _, step in
            if step == .done { brainWorked() }
        }
        .onDisappear { save() }
    }

    // MARK: Hub

    private var hub: some View {
        ScrollView {
            VStack(spacing: Spacing.large) {
                hero
                VStack(spacing: 0) {
                    ForEach(PocketDraft.settings) { setting in
                        PhoneListRow(setting: setting, value: value(setting), lit: lit(setting),
                                     asleepNote: words("imp_settings.brain_marker.asleep", callName)) { pick(setting) }
                            .accessibilityIdentifier("imp.\(setting.rawValue)")
                    }
                }
                .padding(.horizontal, Spacing.medium)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Tone.card))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(words("imp_settings.list.label", callName))
                Button(role: .destructive) { confirmingGoodbye = true } label: {
                    Label { Text(words("imp_settings.goodbye.a11y", callName)) } icon: { Image(systemName: "hand.wave.fill") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.destructive)
                .accessibilityIdentifier("imp.goodbye")
            }
            .padding(.horizontal, Spacing.page).padding(.top, Spacing.small).padding(.bottom, Spacing.wide)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The Imp as it is, never zooming: its size is a setting of the room, not of this picture. Under it its name
    /// and, while it has no Brain, one quiet line that says it sleeps. What it thinks with is the Brain row.
    private var hero: some View {
        VStack(spacing: Spacing.small) {
            if !roomInView { preview.frame(width: Self.heroSide, height: Self.heroSide) }
            Text(verbatim: callName).font(Typeface.title).foregroundStyle(Tone.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if !draft.hasBrain {
                StatusText(verbatim: words("imp_settings.brain_marker.asleep", callName), symbol: "moon.zzz.fill", color: Tone.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.small)
    }

    private static let heroSide = Sizing.marker * 2.6

    private func lit(_ setting: ImpSetting) -> Bool { setting != .brain || draft.hasBrain }

    /// A short state, never a sentence: the model, the name, the size, a count.
    private func value(_ setting: ImpSetting) -> String? {
        switch setting {
        case .brain: return draft.hasBrain ? draft.brain.model : String(localized: "imp_settings.value.asleep")
        case .tools:
            let count = draft.toolCount
            return words("imp_settings.value.tools", count.on, count.all)
        case .look: return "\(Int((draft.scale * 100).rounded()))%"
        // Who it is: its name lives in Personality.
        case .personality: return draft.name.trimmed.isEmpty ? nil : draft.name.trimmed
        case .triggers, .moves: return nil
        }
    }

    /// The Imp, asleep with Zzz. It leans the way the phone tips, as in the room.
    private var preview: some View {
        TiltImp(imp: LinkImp(id: draft.id, name: draft.name, hue: draft.hue, scale: 1, traits: draft.traits), interactive: false)
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
        ScrollViewReader { proxy in
            // The Brain's button stands under the form, above the keyboard while an address or a key is typed.
            FormPage { _ in
                Group {
                    switch setting {
                    case .brain: if let brainFlow { PhoneBrainForm(flow: brainFlow) }
                    case .personality: PocketPersonalityPanel(draft: draft)
                    case .look: PocketLookPanel(draft: draft, showsImp: !roomInView)
                    case .tools: PocketToolsPanel(draft: draft, proxy: proxy, removing: $removing)
                    case .triggers, .moves: EmptyView()
                    }
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.small).padding(.bottom, Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            } footer: {
                if setting == .brain, let brainFlow {
                    PhoneBrainButton(flow: brainFlow, hasBrain: draft.hasBrain)
                        .padding(.horizontal, Spacing.page).padding(.vertical, Spacing.medium)
                }
            }
        }
    }

    private func pick(_ setting: ImpSetting) {
        if setting == .brain { startFlow() }
        withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { open = setting }
    }

    private func leave() {
        save()
        withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { open = nil }
    }

    private func close() {
        save()
        done()
    }

    /// The Brain form for this Imp, with what it has now filled in. A Brain that works is kept at once.
    private func startFlow() {
        let services = FirstRunServices.live(persona: draft.personality.trimmed.isEmpty ? Persona.pocket(named: draft.name.trimmed) : draft.personality,
                                             probeSeconds: Double(Behavior.localProbeTimeoutSeconds),
                                             checkSeconds: Double(Behavior.brainCheckTimeoutSeconds))
        let flow = FirstRunModel(impName: callName, onThisComputer: false, services: services,
                                 preselectsModel: false) { [draft, pocket, id] brain in
            try pocket.adoptFirstRunBrain(brain, for: id)
            draft.adopt(brain, stored: true)
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

    /// The Brain was checked and kept: the sheet goes. An Imp that slept until now opens in its chat.
    private func brainWorked() {
        save()
        if wokeHere { woke() } else { done() }
    }

    /// Whether the Imp had no Brain when the sheet opened, so this sheet is where it woke up.
    @State private var wokeHere = false

    /// Keeps what changed, now or after `delay` (a newer change starts the wait again).
    private func save(after delay: Duration? = nil) {
        saving?.cancel()
        guard let delay else { return keep() }
        saving = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            keep()
        }
    }

    private func keep() {
        guard pocket.contains(id), draft.canSave else { return }
        do {
            try draft.save(into: pocket)
        } catch {
            saveProblem = error.localizedDescription
        }
    }
}
