import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// The main screens in their key states, made the same way every time: fixed Imps (names, colours and
/// ids), no embers, no clock and no pointer. The design renders (`--render-home <scene>`) and the
/// snapshot tests draw these, so the docs show what the tests check.
enum DesignScene: String, CaseIterable {
    case canvasEmpty = "canvas-empty"
    case canvasImps = "canvas-imps"
    case impBrain = "imp-brain"
    case impSleeping = "imp-sleeping"
    case impPersonality = "imp-personality"
    case impLook = "imp-look"
    case impMoves = "imp-moves"
    case impTriggers = "imp-triggers"
    case impTools = "imp-tools"
    case impComputer = "imp-computer"
    case impLookNarrow = "imp-look-narrow"
    case impAgentTools = "imp-agent-tools"
    case impTriggerEditor = "imp-trigger-editor"
    case impTriggerSteps = "imp-trigger-steps"
    case appWide = "all-imps-app"
    case appNarrow = "all-imps-app-narrow"
    case allNothing = "all-imps-nothing"
    case firstRunService = "first-run-service"
    case firstRunError = "first-run-error"
    case barMenu = "bar-menu"
    case barMenuEs = "bar-menu-es"
    case allPair = "all-imps-pair"
    case allBubble = "all-imps-bubble"
    case allTalking = "all-imps-talking"
    case allBrains = "all-imps-brains"
    case allDevices = "all-imps-devices"
    case allDevicesNarrow = "all-imps-devices-narrow"
    case allSharing = "all-imps-sharing"
    case allAnimations = "all-imps-animations"
    case allPrivacy = "all-imps-privacy"
    case allBackup = "all-imps-backup"

    /// The moment the Imps are held at.
    static let still = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var size: CGSize {
        switch self {
        case .canvasEmpty, .canvasImps: CGSize(width: 780, height: 640)
        case .impBrain, .impSleeping, .impPersonality, .impLook, .impMoves, .impTriggers, .impTools, .impComputer: CGSize(width: 760, height: 720)
        case .impLookNarrow: CGSize(width: 380, height: 720)
        case .impAgentTools: CGSize(width: Sizing.sheetWidth, height: 560)
        case .impTriggerEditor: CGSize(width: 600, height: 760)
        case .impTriggerSteps: CGSize(width: 600, height: 960)
        case .appWide: CGSize(width: 900, height: 720)
        case .appNarrow: CGSize(width: 560, height: 720)
        case .allNothing: CGSize(width: 760, height: 640)
        case .firstRunService, .firstRunError: CGSize(width: Sizing.sheetWidth, height: 660)
        case .barMenu, .barMenuEs: CGSize(width: 420, height: 360)
        case .allPair: CGSize(width: 560, height: 420)
        case .allDevicesNarrow: CGSize(width: 380, height: 720)
        case .allBubble, .allTalking, .allBrains, .allDevices, .allSharing, .allAnimations, .allPrivacy, .allBackup: CGSize(width: 760, height: 720)
        }
    }

    @MainActor var view: AnyView {
        let content: AnyView = switch self {
        case .canvasEmpty:
            AnyView(ZStack {
                CanvasBackdrop(html: RoomBackground.defaultHTML)
                EmptyCanvas(action: {})
            })
        case .canvasImps: canvas()
        case .impBrain: impSettings(brain: true, open: .brain)
        case .impSleeping: impSettings(brain: false, open: .brain)
        case .impPersonality: impSettings(brain: true, open: .personality)
        case .impLook, .impLookNarrow: impSettings(brain: true, open: .look)
        case .impMoves: impSettings(brain: true, open: .moves)
        case .impTriggers: impSettings(brain: true, open: .triggers)
        case .impTools: impSettings(brain: true, open: .tools)
        case .impComputer: impSettings(brain: true, open: .computer)
        case .impAgentTools: agentTools()
        case .impTriggerEditor: triggerEditor()
        case .impTriggerSteps: triggerEditor(poke: true)
        case .appWide, .appNarrow: general(.app)
        case .allNothing: general(.brains, setUp: false)
        case .firstRunService: firstRun { _ in }
        case .firstRunError: firstRun { $0.continueFromService() }
        case .barMenu, .barMenuEs: barMenu()
        case .allPair: pairing()
        case .allBubble: general(.bubble)
        case .allTalking: general(.talking)
        case .allBrains: general(.brains)
        case .allDevices: general(.devices)
        case .allSharing: general(.sharing)
        case .allAnimations: general(.animations)
        case .allPrivacy: general(.privacy)
        case .allBackup: general(.backup)
        case .allDevicesNarrow: general(.devices)
        }
        return AnyView(content
            .environment(\.stageStill, Self.still)
            .environment(\.locale, Locale(identifier: self == .barMenuEs ? "es" : "en_US"))
            .frame(width: size.width, height: size.height))
    }

    /// The scene drawn at one pixel to the point, in the light or the dark appearance, once it has settled.
    @MainActor func image(dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))     // layout, and the Imps' pop-in
        defer { window.orderOut(nil) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: Pieces

    /// The menu bar panel on a mid-grey desktop: two Imps out (one hidden) and one at home.
    @MainActor private func barMenu() -> AnyView {
        let model = Self.model(imps: 3)
        model.prefs.imps[0].isActive = true
        model.prefs.imps[1].isActive = true
        model.setHidden(model.prefs.imps[1].id, true)
        return AnyView(StatusPanel(model: model)
            .background(Tone.raised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray))
    }

    /// The link-a-device sheet with a fixed invite, so the QR code is the same every time.
    @MainActor private func pairing() -> AnyView {
        let invite = LinkInvite(device: LinkDevice(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID(), name: "Mac", kind: .mac, key: Data(count: 32)),
                                door: Data(count: 32), invite: Data(count: 32), routes: LinkRoutes(hosts: ["mac.local"]))
        return AnyView(LinkDeviceSheet(model: Self.model(imps: 2), mode: .show, preview: invite).background { Backdrop() })
    }

    /// The Imps of every scene: the same ids, names and colours.
    @MainActor private static func model(imps: Int, brain: Bool = true) -> AppModel {
        let model = AppModel(persist: false)
        model.prefs = ImpPreferences()
        for _ in 1..<max(1, imps) { model.addImp() }
        let ids = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"]
        for (i, hue) in [0.08, 0.57, 0.33].enumerated() where model.prefs.imps.indices.contains(i) {
            model.prefs.imps[i].id = UUID(uuidString: ids[i]) ?? UUID()
            model.prefs.imps[i].hue = hue
            model.prefs.imps[i].name = ["Dot", "Bumble", "Pip"][i]
            model.prefs.imps[i].personality = Persona.newcomer(named: ["Dot", "Bumble", "Pip"][i])
            model.prefs.imps[i].isActive = false
        }
        if brain { model.prefs.ai.add(Service(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2")) }
        return model
    }

    @MainActor private func canvas() -> AnyView {
        let model = Self.model(imps: 3)
        let router = HomeRouter()
        // Where each Imp stands, so the picture does not depend on arrival order.
        for (imp, place) in zip(model.prefs.imps, [CGPoint(x: 0.22, y: 0.4), CGPoint(x: 0.5, y: 0.62), CGPoint(x: 0.78, y: 0.4)]) {
            router.places[imp.id] = place
        }
        return AnyView(HomeView(model: model, router: router))
    }

    @MainActor private func triggerEditor(poke: Bool = false) -> AnyView {
        let model = Self.model(imps: 1)
        let id = model.prefs.imps[0].id
        var trigger = Shortcut(name: "Translate", hotkey: nil, steps: [Step(.ask, value: "Translate this into English.", clipboard: true)])
        if poke {
            model.prefs.imps[0].animations = [MadeAnimation(name: "Wiggle", beats: [])]
            trigger = Shortcut(name: "Ouch", trigger: Trigger(.poke), conditions: [Condition(.hours, value: "09:00-18:00")],
                               steps: [Step(.play, value: "Wiggle"), Step(.say, value: "Ouch!", aloud: true)])
        }
        trigger.performer = id
        return AnyView(ShortcutSheet(model: model, imp: id, shortcut: trigger, isNew: false, scope: .onlyThisImp, save: { _, _ in }, duplicate: { _ in }, delete: {})
            .environment(\.impTint, Color.imp(model.prefs.imps[0].hue))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { SettingsBackdrop() })
    }

    /// What an Imp may do by itself in Moves: the sheet behind the wand.
    @MainActor private func agentTools() -> AnyView {
        let model = Self.model(imps: 1, brain: true)
        let id = model.prefs.imps[0].id
        let imp = Binding(get: { model.profile(id) ?? .imp },
                          set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i] = new } })
        return AnyView(AgentToolsSheet(imp: imp, groups: [.moves])
            .environment(\.impTint, Color.imp(model.prefs.imps[0].hue))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { SettingsBackdrop() })
    }

    @MainActor private func impSettings(brain: Bool, open: ImpSetting? = nil) -> AnyView {
        let model = Self.model(imps: 1, brain: brain)
        let id = model.prefs.imps[0].id
        var trigger = Shortcut(name: "Translate", hotkey: nil, steps: [Step(.ask, value: "Translate this into English.", clipboard: true)])
        trigger.performer = id
        model.prefs.shortcuts = [trigger]
        model.sampleChats[id] = Self.sampleChats()
        return AnyView(ImpSettingsView(model: model, router: HomeRouter(), id: id, open: open).background { SettingsBackdrop() })
    }

    /// A few chats with long titles, at fixed dates, so the Memory rows show their full width.
    private static func sampleChats() -> ChatHistory {
        var history = ChatHistory(folder: nil)
        let asks = ["Plan a three-day trip to Lisbon with museums, food markets and a day at the beach",
                    "Why does my build fail after updating the package?", "Summarise the meeting notes"]
        for (i, ask) in asks.enumerated() {
            if i > 0 { history.startNew() }
            let day = still.addingTimeInterval(Double(i - asks.count) * 86_400)
            for n in 0..<(4 + 3 * i) {
                history.append(ChatTurn(date: day.addingTimeInterval(Double(n) * 60), request: n == 0 ? ask : "And then?", reply: "Here is what I found."))
            }
        }
        return history
    }

    /// A section of the app-wide settings. With `setUp` false there is no Brain and no server, so the
    /// section shows what needs attention.
    @MainActor private func general(_ group: SettingsGroup, setUp: Bool = true) -> AnyView {
        let model = Self.model(imps: 2, brain: setUp)
        if !setUp {
            model.prefs.hop = ""
        }
        let router = HomeRouter()
        router.screen = .general
        router.settingsSection = group
        return AnyView(GeneralSettingsView(model: model, router: router).background { SettingsBackdrop() })
    }

    @MainActor private func firstRun(_ events: (FirstRunModel) -> Void) -> AnyView {
        let services = FirstRunServices(find: { [] }, models: { _, _ in ["model-a", "model-b"] }, check: { _ in })
        let flow = FirstRunModel(impName: "Dot", onThisComputer: true, services: services) { _ in }
        events(flow)
        let hue = 0.08
        return AnyView(FirstRunSheet(flow: flow, hue: hue, traits: .plain, clock: BodyClock(offset: 0), close: {})
            .environment(\.impTint, Color.imp(hue))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { SettingsBackdrop() })
    }
}

/// What the window draws behind a settings screen: the default backdrop with the settings veil (see `HomeView`).
private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            CanvasBackdrop(html: RoomBackground.defaultHTML)
            Tone.veil
        }
    }
}

/// The desktop bubble on its own, over a saturated solid colour instead of the app surface, so a
/// corner artifact or a second background would show. The design renders (`--render-home bubble-short`,
/// add `-light` for the light appearance) and `BubbleSurfaceTests` draw these.
enum BubbleScene: String, CaseIterable {
    case short = "bubble-short"
    case readAll = "bubble-read-all"
    case chat = "bubble-chat"

    /// What the bubble floats over: nothing like the bubble's own colours.
    static let backdrop = NSColor(srgbRed: 0.0, green: 0.62, blue: 0.35, alpha: 1)

    /// `app` outlives the card: the model only holds it unowned.
    @MainActor private func content(app: AppModel) -> BubbleCard {
        let imp = ImpModel(id: app.prefs.imps[0].id, app: app)
        let layout = BubbleLayout()
        let long = (1...14).map { "Paragraph \($0): imps keep their replies short, but sometimes a question deserves a proper answer." }
            .joined(separator: "\n\n")
        switch self {
        case .short:
            return BubbleCard(bubble: Bubble(title: "Talk to Imp", text: "Tomorrow you have a dentist at 10 and lunch with Sam at 1.", phase: .result),
                              model: imp, layout: layout, measuring: true)
        case .readAll:
            layout.textLimit = 210
            return BubbleCard(bubble: Bubble(title: "Talk to Imp", text: long, phase: .result), model: imp, layout: layout, measuring: true)
        case .chat:
            var chat = ChatHistory(folder: nil)
            let date = Date(timeIntervalSinceReferenceDate: 812_000_000)
            chat.append(ChatTurn(date: date, request: "Plan a weekend in Lisbon", reply: "Alfama on Saturday, Belém on Sunday. Pastéis at 9."))
            chat.append(ChatTurn(date: date + 60, request: "And the budget?", reply: "About €300 with food. Pack light."))
            imp.showSample(chat)
            return BubbleCard(bubble: Bubble(phase: .chat), model: imp, layout: layout, measuring: true)
        }
    }

    /// The bubble drawn at one pixel to the point on `backdrop`, in the light or the dark appearance.
    @MainActor func image(dark: Bool) -> NSBitmapImageRep? {
        let app = AppModel(persist: false)
        let host = NSHostingView(rootView: content(app: app))
        defer { withExtendedLifetime(app) {} }
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: host.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = Self.backdrop
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        defer { window.orderOut(nil) }
        guard let frame = window.contentView?.superview ?? window.contentView,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep
    }
}
