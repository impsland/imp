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

/// The room, and the one sheet that may be over it. With nothing linked and no Imp yet, the first screen.
struct RootView: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    /// Which sheet is over the room, and where Close leads (`PhoneRouter`).
    @State private var router = PhoneRouter()
    /// How high the sheet stands: half (the room is alive above it) or the whole screen.
    @State private var detent = PresentationDetent.medium
    @State private var hidden = PhoneHidden()
    /// A round of Embers is on (see `EmbersPlaying`).
    @State private var playing = false
    @State private var toast: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var onStage: Bool { !hub.links.isEmpty || !hub.visits.isEmpty || !pocket.imps.isEmpty }

    /// The share of the room the sheet covers, from the bottom.
    private var cover: CGFloat {
        guard let route = router.route else { return 0 }
        return route.restsAtHalf && detent == .medium ? Behavior.sheetHalfCover : 1
    }

    /// How high the sheet stands, as SwiftUI needs it: always a height this sheet can have.
    private var height: Binding<PresentationDetent> {
        Binding(get: { router.route?.restsAtHalf == false ? .large : detent }, set: { detent = $0 })
    }

    /// The sheet as SwiftUI presents it. Swiping it away goes straight back to the room.
    private var sheet: Binding<PhoneRoute?> {
        Binding(get: { router.route }, set: { if $0 == nil { router.dismissed() } })
    }

    var body: some View {
        ZStack {
            Backdrop()
            if !onStage {
                PairingView(hub: hub, hatch: { router.open(.hatch) }, wake: hatchFirstImp)
                    .transition(.opacity)
            } else {
                PhoneStage(hub: hub, pocket: pocket, hidden: hidden, covered: router.route != nil, cover: cover, guest: router.route?.imp,
                           onChat: { router.talk($0) }, onEdit: { router.open(.edit($0, brain: false)) },
                           onBrain: { router.open(.edit($0, brain: true)) })
                    .transition(.opacity)
                    .onPreferenceChange(EmbersPlaying.self) { playing = $0 }
                VStack {
                    StatusPill(hub: hub, hiddenCount: hidden.set.onFloor(in: PhoneStage.everyone(hub, pocket).map(\.imp.id)).count,
                               devices: { router.open(.settings(devices: true)) }, hatch: { router.open(.hatch) },
                               showHidden: { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { hidden.bringBackAll() } },
                               settings: { router.open(.settings(devices: false)) })
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
        // A new sheet starts at half height when it can rest there, so the room and its Imp stay in view.
        .onChange(of: router.route) { old, new in
            if new == nil || old == nil || (old?.restsAtHalf == false && new?.restsAtHalf == true) { detent = .medium }
        }
        // An Imp that went home, moved away or said goodbye takes its sheet with it.
        .onChange(of: PhoneStage.everyone(hub, pocket).map(\.imp.id)) { old, new in
            for id in old where !new.contains(id) && !pocket.contains(id) { router.left(id) }
        }
        .sheet(item: sheet) { route in
            // Read live: an Imp's sheet stays up while it goes from one Imp to another.
            content(router.route ?? route)
                .presentationDetents(route.restsAtHalf ? [.medium, .large] : [.large], selection: height)
                // The room above a half sheet stays alive: the Imps can be touched, carried and thrown.
                .presentationBackgroundInteraction(route.restsAtHalf ? .enabled(upThrough: .medium) : .disabled)
                .presentationDragIndicator(.visible)
                .presentationBackground(Tone.surface)
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-hatch") { router.open(.hatch) }
            if CommandLine.arguments.contains("-openChat") {
                // Waits for the Imps (from the demo, or from a Mac it's connecting to).
                for _ in 0..<120 where hub.visits.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(1.5))
                if let first = hub.visits.first { router.talk(first.id) }
            }
            // `-ask <text>`: once a visiting Imp is awake, asks the first one and opens its chat (end-to-end checks).
            if let i = CommandLine.arguments.firstIndex(of: "-ask"), CommandLine.arguments.indices.contains(i + 1) {
                for _ in 0..<120 where !(hub.visits.first.map { hub.isAwake($0.id) } ?? false) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let first = hub.visits.first else { return }
                hub.ask(first.id, CommandLine.arguments[i + 1])
                router.talk(first.id)
            }
        }
        #endif
    }

    /// Hatches the first Imp. It has no Brain, so it sleeps, and the path to give it one starts at once.
    private func hatchFirstImp() {
        let imp = PocketImp(name: PairingView.firstName)
        pocket.hatch(imp)
        router.open(.firstRun(imp.id))
    }

    /// Close, in every sheet: back to the Imp's sheet a step was taken from, otherwise to the room.
    private func close() { router.close(exists: { pocket.contains($0) || hub.visit($0) != nil }) }

    @ViewBuilder private func content(_ route: PhoneRoute) -> some View {
        switch route {
        case .imp(let id):
            let own = pocket.contains(id)
            ImpSheet(hub: hub, source: own ? pocket : hub, pocket: pocket, impID: id, pane: $router.pane,
                     roomInView: detent == .medium,
                     edit: own ? { router.open(.edit(id, brain: false)) } : nil,
                     giveBrain: own ? { router.open(.edit(id, brain: true)) } : nil, close: close)
                // Another Imp is another chat: what was being typed and where it was scrolled do not carry over.
                .id(id)
        case .hatch:
            PocketEditor(pocket: pocket, editing: nil, done: close)
        case .edit(let id, let brain):
            PocketEditor(pocket: pocket, editing: id, opening: brain ? .brain : nil, done: close)
        case .firstRun(let id):
            FirstRunPhone(pocket: pocket, id: id, close: close, awake: { router.woke(id) })
        case .settings(let devices):
            DevicesSheet(hub: hub, pocket: pocket, start: devices ? .devices : .brains)
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
