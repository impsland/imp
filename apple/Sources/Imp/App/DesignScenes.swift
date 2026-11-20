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
    case impAnimations = "imp-animations"
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
    case firstRunLocal = "first-run-local"
    case firstRunError = "first-run-error"
    case firstRunFound = "first-run-found"
    case barMenu = "bar-menu"
    case barMenuEs = "bar-menu-es"
    case impMenu = "imp-menu"
    case allPair = "all-imps-pair"
    case allPairLinked = "all-imps-pair-linked"
    case allPairScan = "all-imps-pair-scan"
    case allPairScanError = "all-imps-pair-scan-error"
    case allPairNarrow = "all-imps-pair-narrow"
    case allPairHopCustom = "all-imps-pair-hop-custom"
    case allBubble = "all-imps-bubble"
    case allTalking = "all-imps-talking"
    case allBrains = "all-imps-brains"
    case devicesEmpty = "devices-empty"
    case devicesLinked = "devices-linked"
    case devicesImp = "devices-imp"
    case devicesDevice = "devices-device"
    case devicesEdge = "devices-edge"
    case devicesMac = "devices-mac"
    case devicesVisitor = "devices-visitor"
    case devicesTether = "devices-tether"
    case devicesHop = "devices-hop"
    case devicesHopCustom = "devices-hop-custom"
    case devicesHopOff = "devices-hop-off"
    case allSharing = "all-imps-sharing"
    case allSharingEmpty = "all-imps-sharing-empty"
    case allPrivacy = "all-imps-privacy"
    case allBackup = "all-imps-backup"

    /// The moment the Imps are held at.
    static let still = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var size: CGSize {
        switch self {
        case .canvasEmpty, .canvasImps: CGSize(width: 780, height: 640)
        case .impBrain, .impSleeping, .impPersonality, .impLook, .impAnimations, .impTriggers, .impTools, .impComputer: CGSize(width: 760, height: 720)
        case .impLookNarrow: CGSize(width: 380, height: 720)
        case .impAgentTools: CGSize(width: Sizing.sheetWidth, height: 560)
        case .impTriggerEditor: CGSize(width: 600, height: 760)
        case .impTriggerSteps: CGSize(width: 600, height: 960)
        case .appWide: CGSize(width: 900, height: 720)
        case .appNarrow: CGSize(width: 560, height: 720)
        case .allNothing: CGSize(width: 760, height: 640)
        case .firstRunService, .firstRunLocal, .firstRunError, .firstRunFound: CGSize(width: Sizing.sheetWidth, height: 660)
        case .barMenu, .barMenuEs: CGSize(width: 420, height: 360)
        case .impMenu: CGSize(width: 1480, height: 600)
        case .allPair, .allPairLinked, .allPairScan, .allPairScanError: CGSize(width: 560, height: 420)
        case .allPairNarrow: CGSize(width: 380, height: 640)
        case .devicesEmpty, .devicesLinked: CGSize(width: 1080, height: 720)
        case .devicesImp, .devicesDevice, .devicesEdge, .devicesMac, .devicesVisitor, .devicesTether: CGSize(width: 600, height: 720)
        case .devicesHop, .devicesHopCustom, .devicesHopOff: CGSize(width: 600, height: 460)
        case .allPairHopCustom: CGSize(width: Sizing.popoverWidth + 2 * Spacing.medium, height: 220)
        case .allSharing: CGSize(width: 760, height: 560)
        case .allSharingEmpty: CGSize(width: 760, height: 260)
        case .allBubble, .allTalking, .allBrains, .allPrivacy, .allBackup: CGSize(width: 760, height: 720)
        }
    }

    @MainActor var view: AnyView {
        let content: AnyView = switch self {
        case .canvasEmpty:
            AnyView(HomeView(model: Self.model(imps: 0), router: HomeRouter()))
        case .canvasImps: canvas()
        case .impBrain: impSettings(brain: true, open: .brain)
        case .impSleeping: impSettings(brain: false, open: .brain)
        case .impPersonality: impSettings(brain: true, open: .personality)
        case .impLook, .impLookNarrow: impSettings(brain: true, open: .look)
        case .impAnimations: impSettings(brain: true, open: .animations)
        case .impTriggers: impSettings(brain: true, open: .triggers)
        case .impTools: impSettings(brain: true, open: .tools)
        case .impComputer: impSettings(brain: true, open: .computer)
        case .impAgentTools: agentTools()
        case .impTriggerEditor: triggerEditor()
        case .impTriggerSteps: triggerEditor(poke: true)
        case .appWide, .appNarrow: general(.app)
        case .allNothing: general(.brains, setUp: false)
        case .firstRunService: firstRun { _ in }
        case .firstRunLocal: firstRun { if let local = ServicePreset.local { $0.choose(local) } }
        case .firstRunError: firstRun { $0.continueFromService() }
        case .firstRunFound: firstRun(found: true) { _ in }
        case .barMenu, .barMenuEs: barMenu()
        case .impMenu: impMenu()
        case .allPair: pairing()
        case .allPairLinked: pairing(phase: .linked("Anna's iPhone"))
        case .allPairScan: pairing(mode: .scan)
        case .allPairScanError: pairing(mode: .scan, phase: .failed("Nobody answered. Check that both devices are on the same network, or set a Hop."))
        case .allPairNarrow: pairing(width: 340)
        case .allPairHopCustom: hopPopover()
        case .allBubble: general(.bubble)
        case .allTalking: general(.talking)
        case .allBrains: general(.brains)
        case .allSharing: general(.sharing)
        case .allSharingEmpty: general(.sharing, sharables: false)
        case .allPrivacy: general(.privacy)
        case .allBackup: general(.backup)
        case .devicesEmpty: devices(linked: false)
        case .devicesLinked: devices(linked: true)
        case .devicesImp: deviceSheet(.imp(Self.dotID, in: Self.phoneID.uuidString))
        case .devicesDevice: deviceSheet(.node(Self.phoneID.uuidString))
        case .devicesEdge: deviceSheet(.channel("00000000-0000-4000-8000-0000000000B2"))
        case .devicesMac: deviceSheet(.node(DeviceMap.thisMacID))
        case .devicesVisitor: deviceSheet(.imp(Self.noodleID, in: DeviceMap.thisMacID))
        case .devicesTether: deviceSheet(.tether(Self.dotID, in: Self.phoneID.uuidString))
        case .devicesHop: hopSheet()
        case .devicesHopCustom: hopSheet(choice: .custom)
        case .devicesHopOff: hopSheet(address: "")
        }
        return AnyView(content
            .environment(\.stageStill, Self.still)
            .environment(\.locale, Locale(identifier: self == .barMenuEs ? "es" : "en_US"))
            .frame(width: size.width, height: size.height))
    }

    /// The scene drawn at one pixel to the point, in the light or the dark appearance, once it has settled.
    @MainActor func image(dark: Bool) -> NSBitmapImageRep? {
        // Sheets get the scene as their window, as the app's window would give them (`SheetRoom.available`).
        // Without it they measure the real screen, so a picture would change with the display it was drawn on.
        let host = NSHostingView(rootView: view.environment(\.sheetRoom, size.height - SheetRoom.margin))
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

    /// An Imp's right-click menu card on a mid-grey desktop: on the desktop (Home), in the window (Free), and for
    /// three Imps picked together.
    @MainActor private func impMenu() -> AnyView {
        let model = Self.model(imps: 2)
        let imps = model.prefs.imps
        let raised = RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
        return AnyView(HStack(alignment: .top, spacing: Spacing.wide) {
            ImpMenuCard(ready: true, name: imps[0].name, status: String(localized: "Awake"), hue: imps[0].hue,
                        scale: 1, place: .desktop) { _ in } extra: {
                MenuPills(items: [MenuItem(id: "stop", icon: "stop.circle", title: String(localized: "Stop")) {}])
                MenuPills(title: String(localized: "Triggers"), items: [
                    MenuItem(id: "t1", icon: "globe", title: "Translate") {},
                    MenuItem(id: "t2", icon: "text.badge.checkmark", title: "Proofread") {},
                    MenuItem(id: "t3", icon: "sun.max", title: "Morning") {},
                ])
                MenuPills(title: String(localized: "menu.imp.visit"), items: [MenuItem(id: "p", icon: "iphone.gen3", title: "iPhone") {}])
            }
            .background(Tone.raised, in: raised)
            ImpMenuCard(ready: false, name: imps[1].name, status: String(localized: "Needs a brain"), hue: imps[1].hue,
                        scale: 0.75, place: .home) { _ in } extra: {
                MenuPills(items: [MenuItem(id: "kit", icon: "shippingbox.fill", title: String(localized: "menu.imp.copy_kit")) {},
                                  MenuItem(id: "link", icon: "link", title: String(localized: "menu.imp.copy_link"), enabled: false) {}])
                MenuDangerButton(item: MenuItem(id: "bye", icon: "trash", title: String(localized: "menu.imp.goodbye")) {})
            }
            .background(Tone.raised, in: raised)
            GroupMenuCard(names: imps.map(\.name) + ["Pip"], hues: imps.map(\.hue) + [0.33], scales: [1, 1, 1]) { _ in } extra: {
                MenuPills(title: String(localized: "brain.title"), items: [
                    MenuItem(id: "shared", icon: "person.3.fill", title: String(localized: "brain.use_app"), on: true) {},
                    MenuItem(id: "ollama", icon: "brain", title: "Ollama") {},
                ])
                MenuDangerButton(item: MenuItem(id: "bye", icon: "trash", title: words("menu.group.goodbye", 3)) {})
            }
            .background(Tone.raised, in: raised)
            MenuCard {
                MenuGrid(items: [
                    MenuItem(id: "new", icon: "plus", title: String(localized: "menu.canvas.new_imp")) {},
                    MenuItem(id: "hidden", icon: "eye.fill", title: words("menu.canvas.show_hidden", 2)) {},
                    MenuItem(id: "all", icon: "checkmark.circle.fill", title: String(localized: "menu.canvas.select_all")) {},
                    MenuItem(id: "settings", icon: "gearshape.fill", title: String(localized: "menu.canvas.settings")) {},
                ])
            }
            .fixedSize()
            .background(Tone.raised, in: raised)
        }
        .fixedSize()
        .padding(Spacing.wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray))
    }

    /// The link-a-device sheet with a fixed invite, so the QR code is the same every time.
    @MainActor private func pairing(mode: LinkDeviceSheet.Mode = .show, width: CGFloat = Sizing.sheetWidth, phase: LinkPhase? = nil) -> AnyView {
        let invite = LinkInvite(device: LinkDevice(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID(), name: "Mac", kind: .mac, key: Data(count: 32)),
                                door: Data(count: 32), invite: Data(count: 32), routes: LinkRoutes(hosts: ["mac.local"]))
        return AnyView(LinkDeviceSheet(model: Self.model(imps: 2), mode: mode, width: width, preview: invite, previewPhase: phase).background { Backdrop() })
    }

    private static let dotID = UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID()
    private static let noodleID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C2") ?? UUID()
    private static let phoneID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B1") ?? UUID()

    /// The Devices screen. Linked: Dot is out on Anna's iPhone, which also has its own Imps, Studio Mac is
    /// reached through the Hop and Noodle, from the iPhone, visits this Mac.
    @MainActor private func devices(linked: Bool) -> AnyView {
        let (model, router) = devicesModel(linked: linked)
        return AnyView(DevicesScreen(model: model, router: router).background { SettingsBackdrop() })
    }

    /// The sheet a press on the canvas opens, drawn by itself: the offscreen renderer does not present sheets.
    @MainActor private func deviceSheet(_ selection: DeviceSelection) -> AnyView {
        let (model, router) = devicesModel(linked: true)
        return AnyView(DeviceSheet(model: model, router: router, map: SettingsNodes.deviceMap(for: model), selection: selection) { _ in }
            .background { Backdrop() })
    }

    /// The Hop's sheet; with an `address` of its own, as when none is set or Custom has just been chosen.
    @MainActor private func hopSheet(address: String? = nil, choice: ServerChoice? = nil) -> AnyView {
        let (model, _) = devicesModel(linked: true)
        if choice == .custom { model.prefs.hop = "" } else if let address { model.prefs.hop = address }
        return AnyView(HopSheet(model: model, map: SettingsNodes.deviceMap(for: model), swap: { _ in }, choice: choice)
            .background { Backdrop() })
    }

    /// The Link sheet's Hop popover with Custom chosen and no address yet, drawn by itself: the offscreen renderer
    /// does not present popovers.
    @MainActor private func hopPopover() -> AnyView {
        AnyView(HopPopoverScene())
    }

    @MainActor private func devicesModel(linked: Bool) -> (AppModel, HomeRouter) {
        let model = Self.model(imps: 3)
        if linked {
            model.prefs.hop = "hop.example.org:4677"
            func look(_ name: String, _ hue: Double, _ id: String) -> LinkImp {
                LinkImp(id: UUID(uuidString: id) ?? UUID(), name: name, hue: hue, scale: 1, traits: .plain)
            }
            model.prefs.imps[0].awayOn = Self.phoneID
            let cinder = look("Cinder", 0.9, "00000000-0000-4000-8000-0000000000C1")
            let noodle = look("Noodle", 0.45, "00000000-0000-4000-8000-0000000000C2")
            let stage = [LinkStaged(imp: LinkImp(model.prefs.imps[0]), home: UUID()),
                         LinkStaged(imp: cinder, home: Self.phoneID), LinkStaged(imp: noodle, home: Self.phoneID)]
            model.link.showSample([
                .init(id: Self.phoneID, name: "Anna's iPhone", kind: .phone, reach: .direct, imps: [Self.dotID], isTrusted: true, stage: stage,
                      routes: LinkRoutes(hosts: ["annas-iphone.local"], port: 47824)),
                .init(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000B2") ?? UUID(), name: "Studio Mac", kind: .mac, reach: .viaServer, imps: [], isTrusted: true),
            ], visitors: [LinkStaged(imp: noodle, home: Self.phoneID)])
        }
        let router = HomeRouter()
        router.screen = .devices
        return (model, router)
    }

    /// The Imps of every scene: the same ids, names and colours.
    @MainActor private static func model(imps: Int, brain: Bool = true) -> AppModel {
        let model = AppModel(persist: false)
        model.prefs = ImpPreferences()
        for _ in 0..<imps { model.addImp() }
        let ids = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"]
        // Colours and secret favourites are fixed (a newcomer's favourite is random), and far apart, so no
        // picture shows the favourite's heart by chance.
        for (i, (hue, favorite)) in [(0.08, 0.75), (0.57, 0.2), (0.33, 0.9)].enumerated() where model.prefs.imps.indices.contains(i) {
            model.prefs.imps[i].id = UUID(uuidString: ids[i]) ?? UUID()
            // The favourite before the colour: changing the colour onto a (random) favourite marks it found.
            model.prefs.imps[i].favoriteHue = favorite
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

    /// What an Imp may do by itself in Animations: the sheet behind the wand.
    @MainActor private func agentTools() -> AnyView {
        let model = Self.model(imps: 1, brain: true)
        let id = model.prefs.imps[0].id
        let imp = Binding(get: { model.profile(id) ?? .imp },
                          set: { new in if let i = model.prefs.imps.firstIndex(where: { $0.id == id }) { model.prefs.imps[i] = new } })
        return AnyView(AgentToolsSheet(imp: imp, groups: [.animations])
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
    /// section shows what needs attention. With `sharables` false Sharing has nothing to list.
    @MainActor private func general(_ group: SettingsGroup, setUp: Bool = true, sharables: Bool = true) -> AnyView {
        let model = Self.model(imps: 2, brain: setUp)
        if !setUp {
            model.prefs.hop = ""
        }
        if group == .sharing, sharables { Self.addSharables(to: model) }
        let router = HomeRouter()
        router.screen = .general
        router.settingsSection = group
        return AnyView(GeneralSettingsView(model: model, router: router).background { SettingsBackdrop() })
    }

    /// Something of each kind to share: shared and own triggers and animations, a tool two Imps use and one nobody does.
    @MainActor private static func addSharables(to model: AppModel) {
        let bumble = model.prefs.imps[1].id
        let beats = [AnimationBeat(duration: 0.5, mood: "excited", hop: true), AnimationBeat(duration: 0.8, mood: "happy", tilt: 6)]
        model.prefs.animationLibrary = [MadeAnimation(name: "Wave", about: "A small hello.", beats: beats)]
        model.prefs.imps[0].animations = [MadeAnimation(name: "Spin", beats: beats)]
        model.prefs.shortcuts = [
            Shortcut(name: "Translate", hotkey: Hotkey(parsing: "ctrl+opt+T"),
                     steps: [Step(.ask, value: "Translate this into English.", clipboard: true)]),
            Shortcut(name: "Greet", performer: bumble, trigger: .starter(.click), steps: [Step(.play, value: "Wave")]),
        ]
        let files = MCPServerConfig(name: "Files", transport: .stdio, command: "npx",
                                    arguments: ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"])
        model.prefs.mcpServers = [files, MCPServerConfig(name: "Notes", transport: .http, url: "https://notes.example.com/mcp")]
        model.prefs.imps[0].servers = [files.id]
        model.prefs.imps[1].servers = [files.id]
    }

    /// The first run of a new Imp (not in the settings), as on the first launch: with Ollama found when `found`.
    @MainActor private func firstRun(found: Bool = false, _ events: (FirstRunModel) -> Void) -> AnyView {
        let ollama = LocalServer(name: "Ollama", baseURL: ServicePreset.local?.baseURL ?? "", models: ["llama3.2"])
        let services = FirstRunServices(find: { found ? [ollama] : [] }, models: { _, _ in ["model-a", "model-b"] }, check: { _ in })
        var imp = ImpProfile.imp
        imp.name = "Dot"
        imp.hue = 0.08
        let flow = FirstRunModel(impName: imp.name, target: .newImp(imp), onThisComputer: true, services: services,
                                found: found ? [ollama] : []) { _, _ in }
        events(flow)
        let hue = imp.hue
        return AnyView(FirstRunSheet(flow: flow, hue: hue, traits: .plain, clock: BodyClock(offset: 0), linkDevice: {}, close: {})
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
    case permission = "bubble-permission"
    case thinking = "bubble-thinking"
    case thoughts = "bubble-thoughts"

    /// What the bubble floats over: nothing like the bubble's own colours.
    static let backdrop = NSColor(srgbRed: 0.0, green: 0.62, blue: 0.35, alpha: 1)

    /// `app` outlives the card: the model only holds it unowned.
    @MainActor private func content(app: AppModel) -> BubbleCard {
        let imp = ImpModel(id: app.addImp(), app: app)
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
        case .permission:
            // Working, a command already refused before it, and the question about the next one (long, so it is cut).
            let steps = [Bubble.Step(icon: "terminal", title: "Run a command", state: .failed, tool: "shell", request: "rm -rf ~/old", response: "Not allowed by your permissions: shell rm -rf ~/old"),
                         Bubble.Step(icon: "terminal", title: "Run a command", tool: "shell", request: "")]
            var bubble = Bubble(title: "Tidy my downloads", text: "Poking the cloud…", phase: .thinking, steps: steps)
            bubble.permission = Bubble.Prompt(action: "shell", resource: "mv ~/Downloads/*.pdf ~/Documents/Papers/2026/inbox/from-downloads", more: 1)
            return BubbleCard(bubble: bubble, model: imp, layout: layout, measuring: true)
        case .thinking:
            // The model is thinking: its newest words stream in a block of fixed height under the row.
            let reasoning = "The user wants a weekend plan for Lisbon. Alfama is best on foot in the morning, before the heat. "
                + "Belém is across town, so it deserves its own day. Pastéis de nata are best fresh, so before ten. "
                + "Then a viewpoint for the evening: Miradouro da Senhora do Monte faces the sunset over the castle."
            let steps = [Bubble.Step(icon: "magnifyingglass", title: "Search the web", state: .done, tool: "web", request: "{\"query\":\"Lisbon weekend\"}", response: "…"),
                         { var live = Bubble.Step.thinking(reasoning); live.title = "Thinking…"; return live }()]
            return BubbleCard(bubble: Bubble(title: "Plan a weekend in Lisbon", text: "Poking the cloud…", phase: .thinking, steps: steps),
                              model: imp, layout: layout, measuring: true)
        case .thoughts:
            // Two thoughts among tool steps, collapsed; the second one is open.
            // The scene's titles are written out: a bare build has no String Catalog to look them up in.
            func thought(_ text: String, seconds: Int) -> Bubble.Step {
                var step = Bubble.Step(ChatTurn.Step.thought(text, seconds: Double(seconds)))
                step.title = "Thought for \(seconds)s"
                return step
            }
            let open = thought("Alfama first, on foot. Belém the next day.\nThen the tram 28 for the evening.", seconds: 4)
            layout.openSteps = [open.id]
            let steps = [thought("Search for opening hours first.", seconds: 2),
                         Bubble.Step(icon: "magnifyingglass", title: "Search the web", state: .done, tool: "web", request: "{\"query\":\"Lisbon weekend\"}", response: "…"),
                         open,
                         Bubble.Step(icon: "calendar", title: "Add an event", state: .running, tool: "calendar", request: "")]
            return BubbleCard(bubble: Bubble(title: "Plan a weekend in Lisbon", text: "Summoning answers…", phase: .thinking, steps: steps),
                              model: imp, layout: layout, measuring: true)
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

/// The Hop card as the Link sheet's popover shows it, on the sheet's surface.
private struct HopPopoverScene: View {
    @State private var hop = ""

    var body: some View {
        ServerCard(kind: .hop, text: $hop, choice: .custom)
            .padding(Spacing.medium)
            .frame(width: Sizing.popoverWidth)
            .background { Backdrop() }
    }
}
