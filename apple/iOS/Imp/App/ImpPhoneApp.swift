import ImpDesign
import ImpKit
import SwiftUI

@main
struct ImpPhoneApp: App {
    @State private var hub: LinkHub
    @State private var pocket: PocketRuntime
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let hub = LinkHub()
        #if DEBUG
        // End-to-end checks against a real Mac in the Simulator: `-join <implink://…>` links at launch.
        if let i = CommandLine.arguments.firstIndex(of: "-join"), CommandLine.arguments.indices.contains(i + 1) {
            hub.join(code: CommandLine.arguments[i + 1])
        }
        #endif
        _hub = State(initialValue: hub)
        _pocket = State(initialValue: PocketRuntime(hub: hub))
    }

    var body: some Scene {
        WindowGroup {
            RootView(hub: hub, pocket: pocket)
                .phoneAppearance()
                .tint(Tone.accent)
                .onOpenURL { url in
                    // A link to join opened from the Camera app (or Notes, Messages…).
                    if !hub.join(code: url.absoluteString) { hub.toast = String(localized: "phone.pair.link_bad") }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in hub.setScene(phase) }
        }
    }
}

/// Linking when there's nothing yet; the stage once there's a linked device or an Imp hatched on this iPhone.
struct RootView: View {
    /// What's in the sheet.
    private enum Sheet: Hashable, Identifiable {
        case chat(UUID)
        case hatch
        case edit(UUID)
        /// The editor of a pocket Imp with its Brain panel open.
        case brain(UUID)
        case talks(UUID)
        case devices
        case settings
        case firstRun(UUID)

        var id: Self { self }
        var isChat: Bool { if case .chat = self { true } else { false } }
        var isSettings: Bool { switch self { case .settings, .devices: true; default: false } }
    }

    let hub: LinkHub
    let pocket: PocketRuntime
    @State private var sheet: Sheet?
    @State private var hidden = PhoneHidden()
    /// A round of Embers is on (see `EmbersPlaying`).
    @State private var playing = false
    @State private var toast: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onStage: Bool { !hub.links.isEmpty || !hub.visits.isEmpty || !pocket.imps.isEmpty }

    var body: some View {
        ZStack {
            Backdrop()
            if !onStage {
                PairingView(hub: hub, hatch: { sheet = .hatch }, wake: hatchFirstImp)
                    .transition(.opacity)
            } else {
                PhoneStage(hub: hub, pocket: pocket, hidden: hidden, covered: sheet != nil, onChat: { sheet = .chat($0) }, onEdit: { sheet = .edit($0) }, onTalks: { sheet = .talks($0) }, onBrain: { sheet = .brain($0) })
                    .transition(.opacity)
                    .onPreferenceChange(EmbersPlaying.self) { playing = $0 }
                VStack {
                    StatusPill(hub: hub, hiddenCount: hidden.set.onFloor(in: PhoneStage.everyone(hub, pocket).map(\.imp.id)).count,
                               devices: { sheet = .devices }, hatch: { sheet = .hatch },
                               showHidden: { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { hidden.bringBackAll() } }, settings: { sheet = .settings })
                    Spacer()
                }
                .opacity(playing ? 0 : 1)
                .offset(y: playing ? -Spacing.medium : 0)
                .allowsHitTesting(!playing)
                .impAnimation(ImpDesign.Motion.spring, value: playing)
            }
        }
        .impAnimation(ImpDesign.Motion.scene, value: onStage)
        .impControls(tint: Tone.accent)
        .overlay(alignment: .bottom) { ToastView(text: toast).padding(.bottom, Spacing.huge) }
        .onChange(of: hub.toast) { _, text in
            guard let text else { return }
            toast = text
            hub.toast = nil
            Task {
                try? await Task.sleep(for: .seconds(Behavior.toastSeconds))
                if toast == text { toast = nil }
            }
        }
        .sheet(item: $sheet) { route in
            content(route)
                .presentationDetents(route.isChat || route.isSettings ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Tone.surface)
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-hatch") { sheet = .hatch }
            if CommandLine.arguments.contains("-openChat") {
                // Waits for the Imps (from the demo, or from a Mac it's connecting to).
                for _ in 0..<120 where hub.visits.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(1.5))
                if let first = hub.visits.first { sheet = .chat(first.id) }
            }
            // `-ask <text>`: once a visiting Imp is awake, asks the first one and opens its chat (end-to-end checks).
            if let i = CommandLine.arguments.firstIndex(of: "-ask"), CommandLine.arguments.indices.contains(i + 1) {
                for _ in 0..<120 where !(hub.visits.first.map { hub.isAwake($0.id) } ?? false) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let first = hub.visits.first else { return }
                hub.ask(first.id, CommandLine.arguments[i + 1])
                sheet = .chat(first.id)
            }
        }
        #endif
    }

    /// Hatches the first Imp. It has no Brain, so it sleeps, and the path to give it one starts at once.
    private func hatchFirstImp() {
        let imp = PocketImp(name: PairingView.firstName)
        pocket.hatch(imp)
        sheet = .firstRun(imp.id)
    }

    /// A short message at the bottom that goes by itself.
    private func say(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(Behavior.toastSeconds))
            if toast == text { toast = nil }
        }
    }

    @ViewBuilder private func content(_ route: Sheet) -> some View {
        switch route {
        case .chat(let id):
            if pocket.contains(id) {
                ChatSheet(hub: hub, source: pocket, pocket: pocket, impID: id, edit: { sheet = .edit(id) }, giveBrain: { sheet = .brain(id) })
            } else {
                ChatSheet(hub: hub, source: hub, pocket: pocket, impID: id)
            }
        case .talks(let id):
            TalksSheet(hub: hub, pocket: pocket, impID: id)
        case .hatch:
            PocketEditor(pocket: pocket, editing: nil, done: { sheet = nil })
        case .edit(let id):
            PocketEditor(pocket: pocket, editing: id, done: { sheet = pocket.contains(id) ? .chat(id) : nil })
        case .brain(let id):
            PocketEditor(pocket: pocket, editing: id, opening: .brain, done: { sheet = pocket.contains(id) ? .chat(id) : nil })
        case .firstRun(let id):
            FirstRunPhone(pocket: pocket, id: id, close: { sheet = nil }, awake: { sheet = .chat(id) })
        case .devices:
            DevicesSheet(hub: hub, pocket: pocket, start: .devices)
        case .settings:
            DevicesSheet(hub: hub, pocket: pocket)
        }
    }
}

/// A small message that floats up and goes.
struct ToastView: View {
    var text: String?
    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(Typeface.label)
                    .foregroundStyle(Tone.text)
                    .padding(.horizontal, Spacing.large).padding(.vertical, Spacing.cozy)
                    .background(Tone.raised, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .impAnimation(ImpDesign.Motion.spring, value: text)
    }
}
