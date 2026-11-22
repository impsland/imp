import ImpDesign
import ImpKit
import SwiftUI

@main
struct ImpPhoneApp: App {
    @State private var hub: LinkHub
    @State private var pocket: PocketRuntime
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before the hub reads its links: a reinstall must not come back linked (and ask for the network).
        InstallRecord.clearLeftovers()
        let hub = LinkHub()
        #if DEBUG
        // End-to-end checks against a real Mac in the Simulator: `-join <implink://…>` links at launch.
        if let i = CommandLine.arguments.firstIndex(of: "-join"), CommandLine.arguments.indices.contains(i + 1) {
            hub.join(code: CommandLine.arguments[i + 1])
        }
        #endif
        PhoneLibrary.prepareFolders()
        _hub = State(initialValue: hub)
        _pocket = State(initialValue: PocketRuntime(hub: hub, store: Self.store()))
    }

    /// The Imps hatched here. The UI tests (`-uiTestSandbox`, debug builds only) get a file of their own, so a test never
    /// sees or touches the owner's Imps, and `-uiTestReset` empties it (keys too) for a test that starts from nothing.
    private static func store() -> PocketStore {
        #if DEBUG
        if CommandLine.arguments.contains("-uiTestSandbox") {
            let sandbox = PocketStore(url: URL.applicationSupportDirectory.appending(path: "pocket-imps-uitest.json"))
            if CommandLine.arguments.contains("-uiTestReset") { for imp in sandbox.imps { sandbox.remove(imp.id) } }
            return sandbox
        }
        #endif
        return PocketStore()
    }

    var body: some Scene {
        WindowGroup {
            RootView(hub: hub, pocket: pocket)
                .energyScope()
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
    /// The keyboard is up. It lifts a half sheet over the room, as if the sheet stood at full height.
    @State private var keyboardUp = false
    @State private var hidden = PhoneHidden()
    #if DEBUG
    @State private var debugCamera = false
    #endif
    /// A round of Embers is on (see `EmbersPlaying`).
    @State private var playing = false
    /// Imps are being picked together: the picking bar takes the top bar's place.
    @State private var picking = false
    @State private var toast: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var onStage: Bool { !hub.links.isEmpty || !hub.visits.isEmpty || !pocket.imps.isEmpty }

    /// The room is in view above the sheet: it rests at half height and no keyboard lifts it.
    /// The one answer the stage (where the Imp waits) and the sheet (whether its bar shows the Imp) share.
    private var roomInView: Bool { router.route?.restsAtHalf == true && detent == .medium && !keyboardUp }

    /// The share of the room the sheet covers, from the bottom.
    private var cover: CGFloat {
        guard router.route != nil else { return 0 }
        return roomInView ? Behavior.sheetHalfCover : 1
    }

    /// How high the sheet stands, as SwiftUI needs it: always a height this sheet can have.
    private var height: Binding<PresentationDetent> {
        Binding(get: { router.route?.restsAtHalf == false ? .large : detent }, set: { detent = $0 })
    }

    /// Who is here, for the sheets: an Imp's sheet closes once it is somewhere else.
    private var presence: PhonePresence {
        PhonePresence(room: PhoneStage.everyone(hub, pocket).map(\.imp.id), own: Set(pocket.imps.map(\.id)), away: hub.away)
    }

    /// Whether the sheet is up. There is one sheet, whatever it shows: it stays up while it goes from the chat to
    /// the settings or from one Imp to another, and only its content and its height change. Swiping it away goes
    /// straight back to the room.
    private var sheetUp: Binding<Bool> {
        Binding(get: { router.route != nil }, set: { if !$0 { router.dismissed() } })
    }

    /// What the sheet shows: the route, or while it slides away, the one it showed last.
    @State private var shownRoute: PhoneRoute?

    var body: some View {
        ZStack {
            Backdrop()
            // The page the Imps drew behind the room (`PhoneBackground`), once there is a room.
            if onStage {
                HTMLBackdrop(html: PhoneBackground.shared.html, plain: RoomBackground.defaultHTML, live: scenePhase == .active)
                    .transition(.opacity)
            }
            if !onStage {
                PairingView(hub: hub, wake: hatchFirstImp)
                    .transition(.opacity)
            } else {
                PhoneStage(hub: hub, pocket: pocket, hidden: hidden, covered: router.route != nil, cover: cover, guest: router.route?.imp,
                           onChat: { router.talk($0) }, onEdit: { router.open(.edit($0, brain: false)) },
                           onBrain: { router.open(.edit($0, brain: true)) })
                    .transition(.opacity)
                    // A keyboard in a sheet is not the room's business: it would lay the stage out again as it came.
                    .keyboardIgnored()
                    .onPreferenceChange(EmbersPlaying.self) { playing = $0 }
                    .onPreferenceChange(PhonePicking.self) { picking = $0 }
                VStack {
                    StatusPill(hub: hub, hiddenCount: hidden.set.onFloor(in: PhoneStage.everyone(hub, pocket).map(\.imp.id)).count,
                               devices: { router.open(.settings(devices: true)) }, hatch: hatchNew,
                               showHidden: { withImpAnimation(ImpDesign.Motion.smooth, reduceMotion: reduceMotion) { hidden.bringBackAll() } },
                               settings: { router.open(.settings(devices: false)) })
                    Spacer()
                }
                .keyboardIgnored()
                .opacity(playing || picking ? 0 : 1)
                .offset(y: playing ? -Spacing.medium : 0)
                .allowsHitTesting(!playing && !picking)
                .impAnimation(ImpDesign.Motion.spring, value: playing)
                .impAnimation(ImpDesign.Motion.fade, value: picking)
            }
        }
        .impAnimation(ImpDesign.Motion.scene, value: onStage)
        // Only a half sheet over the room cares: every other sheet is full height and nothing around it
        // changes. Telling the whole room about each keyboard made it redo its work as the keyboard came.
        .onKeyboard { up in
            let lifts = up && router.route?.restsAtHalf == true
            if keyboardUp != lifts { keyboardUp = lifts }
        }
        .impControls(tint: Tone.accent)
        #if DEBUG
        .fullScreenCover(isPresented: $debugCamera) {
            CameraView(imps: PhoneStage.everyone(hub, pocket).map(\.imp).filter { !hidden.set.contains($0.id) },
                       onSend: { _ in debugCamera = false }, close: { debugCamera = false })
        }
        #endif
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
        // Something new in the sheet starts at half height when it can rest there, so the room and its Imp stay in
        // view: the same from the room or from another sheet. Going from one Imp's chat to another's keeps the height.
        .onChange(of: router.route) { old, new in
            if let new { withImpAnimation(ImpDesign.Motion.scene, reduceMotion: reduceMotion) { shownRoute = new } }
            if new == nil || old?.id != new?.id { detent = .medium }
        }
        // An Imp that went home, moved away or said goodbye takes its sheet with it. One of this iPhone thrown to
        // another device takes its chat too, once that device has it: it can't be in two places (`PhoneRouter.departed`).
        .onChange(of: presence) { old, new in router.roomChanged(from: old, to: new) }
        // One sheet for every route, so each looks and behaves the same however it was reached (from the room, or
        // from another sheet): the grab bar on top, half height where the room should stay in view, full height for
        // settings that need the whole screen. Changing what it shows never puts it away and brings another.
        .sheet(isPresented: sheetUp) {
            if let route = router.route ?? shownRoute {
                content(route)
                    // Each kind of sheet starts fresh (the same Imp's chat is the same view).
                    .id(route.id)
                    // A sheet is its own presentation: the appearance has to reach it too, or it keeps the
                    // light or dark look it opened with until it is shown again.
                    .phoneAppearance()
                    .transition(.opacity)
                    .presentationDetents(route.restsAtHalf ? [.medium, .large] : [.large], selection: height)
                    // The room above a half sheet stays alive: the Imps can be touched, carried and thrown.
                    .presentationBackgroundInteraction(route.restsAtHalf ? .enabled(upThrough: .medium) : .disabled)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Tone.surface)
            }
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-hatch") { hatchNew() }
            // Three Imps in the room and no sheet over it, for the UI test of picking several.
            if CommandLine.arguments.contains("-hatchThree") { for _ in 0..<3 { pocket.hatchReady() } }
            // A page behind the room that moves and is larger than the screen, as an Imp may draw (UI tests of the room's layout).
            if CommandLine.arguments.contains("-uiTestBackground") { PhoneBackground.shared.set(PhoneBackground.uiTestPage) }
            // For the UI tests on a device: the app's settings, or the first Imp hatched here in its settings.
            if CommandLine.arguments.contains("-openSettings") { router.open(.settings(devices: false)) }
            // The playful camera over the room, with the Imps that are on it (after the Imps are hatched).
            if CommandLine.arguments.contains("-openCamera") {
                try? await Task.sleep(for: .seconds(1.5))
                debugCamera = true
            }
            if CommandLine.arguments.contains("-openDevices") { router.open(.settings(devices: true)) }
            if CommandLine.arguments.contains("-editImp"), let first = pocket.imps.first { router.open(.edit(first.id, brain: false)) }
            // A pocket Imp with a (pretend) Brain, so its chat is open for the UI tests of attachments. Nothing is asked of it.
            if CommandLine.arguments.contains("-openPocketChat") {
                let (id, _) = pocket.hatchReady()
                pocket.edit(id) { $0.brain.baseURL = "http://127.0.0.1:9/v1"; $0.brain.model = "test" }
                try? await Task.sleep(for: .seconds(1))
                router.talk(id)
            }
            if CommandLine.arguments.contains("-openChat") {
                // Waits for the Imps (from a Mac it's connecting to).
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

    /// The first Imp: the first run opens, and the Imp is made by its last step.
    private func hatchFirstImp() {
        router.open(.firstRun(UUID()))
    }

    /// New Imp: it is in the room at once, thinking with the Brain the other Imps here use. The first one of all has
    /// no Brain to share, so its Brain comes up to give it one.
    private func hatchNew() {
        let (id, awake) = pocket.hatchReady()
        if !awake { router.open(.edit(id, brain: true)) }
    }

    /// Close, in every sheet: back to the Imp's sheet a step was taken from (while that Imp is here), otherwise to the room.
    private func close() { router.close(exists: { (pocket.contains($0) && !hub.away.contains($0)) || hub.visit($0) != nil }) }

    @ViewBuilder private func content(_ route: PhoneRoute) -> some View {
        switch route {
        case .imp(let id):
            let own = pocket.contains(id)
            ImpSheet(hub: hub, source: own ? pocket : hub, pocket: pocket, impID: id, pane: $router.pane,
                     roomInView: roomInView,
                     edit: own ? { router.open(.edit(id, brain: false)) } : nil,
                     giveBrain: own ? { router.open(.edit(id, brain: true)) } : nil,
                     onScreen: PhoneStage.everyone(hub, pocket).map(\.imp).filter { !hidden.set.contains($0.id) }, close: close)
                // Another Imp is another chat: what was being typed and where it was scrolled do not carry over.
                .id(id)
        case .edit(let id, let brain):
            PocketEditor(pocket: pocket, editing: id, opening: brain ? .brain : nil, roomInView: roomInView, done: close, woke: { router.woke(id) })
        case .firstRun(let id):
            OnboardingPhone(pocket: pocket, id: id, close: close, finished: { router.woke($0) })
        case .settings(let devices):
            DevicesSheet(hub: hub, pocket: pocket, start: devices ? .devices : .brains,
                         openBrain: { router.open(.edit($0, brain: true)) })
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
