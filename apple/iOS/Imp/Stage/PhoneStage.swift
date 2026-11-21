import CoreMotion
import ImpDesign
import ImpKit
import SwiftUI

/// The phone's room: Imps floating in the dungeon, to drag, toss, tap and shake.
struct PhoneStage: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    /// The Imps the person hid: they leave the stage and peek from the floor.
    let hidden: PhoneHidden
    /// A sheet is over the stage (chat, editor, devices): a shake there is not meant for the Imps.
    var covered = false
    /// The share of the room's height the sheet covers, from the bottom. The room above it stays alive.
    var cover: CGFloat = 0
    /// The Imp the sheet is about: it comes up into the room left above the sheet and waits there.
    var guest: UUID?
    var onChat: (UUID) -> Void
    /// Opens an Imp hatched here in the editor.
    var onEdit: (UUID) -> Void = { _ in }
    /// Opens what the Imp said with other Imps.
    /// Starts waking an Imp hatched here that has no Brain.
    var onBrain: (UUID) -> Void = { _ in }
    /// An Imp hatched here, waiting for "Move to" a Mac to be confirmed.
    @State private var moving: (imp: LinkImp, mac: LinkDevice)?
    /// A shake that wants the person to pick where the Imp goes.
    @State private var asking: ShakeAsk?
    @State private var engine = StageEngine()
    @State private var motion = MotionWatcher()
    @State private var sizes = BubbleSizes()
    /// How fast the stage is drawn right now (the engine says, `FramePolicy` turns it into frames).
    @State private var activity = FramePolicy.Activity.lively
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var wired = false
    /// The Imp whose context menu was just asked for: its bubble is gone and its name tag hidden, so nothing stays behind the lifted preview.
    @State private var menuFor: UUID?
    /// The Imp whose menu is open.
    @State private var menuImp: UUID?
    /// Whether Imps are being picked together (Select in an Imp's menu), and which ones are picked so far.
    @State private var picking = false
    @State private var picked: Set<UUID> = []
    /// The Imps hatched here that the person chose Goodbye for, asked about once for all of them.
    @State private var sayingGoodbye: [LinkImp]?

    var body: some View {
        menus
        .onChange(of: staged) {
            engine.reconcile(roster)
            hub.setStage(staged)
        }
        .onChange(of: everyone.map(\.id)) { _, ids in hidden.forget(except: ids) }
        .onChange(of: motionInterval, initial: true) { _, interval in
            if let interval { motion.start(interval: interval) } else { motion.stop() }
        }
        // Back in front or uncovered: one lively frame to catch up, then the pace follows the Imps.
        .onChange(of: scenePhase == .active && !veiled) { _, shown in if shown { engine.pacer.wake() } }
        .onChange(of: guest) { engine.pacer.wake() }
        .onChange(of: cover) { engine.pacer.wake() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // A voice doesn't go on talking from a phone that's been put away.
            if phase == .background { StageVoice.shared.interrupt() }
            // Echo's sound and haptic engines run only while the app is in front.
            if phase == .active { engine.echo?.resume() } else { engine.echo?.rest() }
        }
    }

    /// The room with picking over it and the questions the Imps' menus lead to. Split from `body` so the compiler
    /// can type-check each part.
    private var questions: some View {
        room
        .overlay { pickingBars }
        .impAnimation(ImpDesign.Motion.fade, value: picking)
        .preference(key: PhonePicking.self, value: picking)
        .onChange(of: staged) { prunePicks() }
        .onChange(of: covered) { if covered { endPicking() } }
        .onChange(of: engine.isBlocking) { if engine.isBlocking { endPicking() } }
        .goodbyeQuestion(goodbyeIds, names: (sayingGoodbye ?? []).map(\.name)) { ids in
            for id in ids { pocket.delete(id) }
            Haptics.notify(.success)
            endPicking()
        }
        .confirmationDialog(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { ask in
            ForEach(ask.choices) { device in
                Button(words("menu.imp.send_to", device.name)) { sendShaken(ask.imp, to: device.id, side: nil) }
            }
        } message: { Text($0.message) }
    }

    /// The Imp's menu and the questions it leads to.
    private var menus: some View {
        questions
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in motion.configure() }
        .confirmationDialog(menuImp.flatMap { engine.bodies[$0]?.imp.name } ?? "",
                            isPresented: Binding(get: { menuImp != nil }, set: { if !$0 { menuImp = nil; menuFor = nil } }),
                            titleVisibility: .visible, presenting: menuImp.flatMap { engine.bodies[$0] }) { body in
            let source: any ChatSource = pocket.contains(body.imp.id) ? pocket : hub
            menu(for: body, source: source, awake: source.availability(body.imp.id) == .ready)
        }
        .confirmationDialog(moving.map { words("phone.stage.move.title", $0.imp.name, $0.mac.name) } ?? "",
                            isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                            titleVisibility: .visible, presenting: moving) { move in
            Button("Move") { engine.sendGently(move.imp.id, to: move.mac.id, moves: true) }
        } message: { move in
            Text(words("phone.stage.move.body", move.imp.name, move.mac.name))
        }
    }

    /// The room itself: the Imps and what sits on the floor. Split from `body` so the compiler can type-check each half.
    private var room: some View {
        // The stage runs edge to edge, so the screen's safe area (notch, Dynamic Island, home
        // indicator) is measured outside it, for what has to stay clear of them.
        GeometryReader { screen in
            GeometryReader { geo in
                ZStack {
                    // Touches that miss every Imp still make them look.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                            .onChanged { menuFor = nil; engine.touch = $0.location; engine.pacer.wake() }
                            .onEnded { _ in engine.touch = nil })

                    PacedTimeline(activity: activity) { date in
                        let _ = call(in: geo.size, top: screen.safeAreaInsets.top)
                        let _ = engine.step(date, size: geo.size, insets: geo.safeAreaInsets, tilt: motion.tilt)
                        // Talks with other Imps: over the talker's head, or under it or beside it when that is where there is
                        // room, always on screen, above a half sheet, and never over another bubble.
                        // None while a game is on: the bubbles that arrive meanwhile are held by the hub and show when it ends.
                        let places = engine.isPlaying ? [:] : bubbles(size: geo.size, insets: screen.safeAreaInsets, date: date)
                        ZStack {
                            EchoFloor(engine: engine, date: date, reduceMotion: engine.reduceMotion)
                            ForEach(engine.order, id: \.self) { id in
                                if let body = engine.bodies[id] {
                                    figure(body, date: date, talking: places[id] != nil)
                                }
                            }
                            ForEach(engine.order, id: \.self) { id in
                                if let b = engine.bodies[id], let place = places[id] {
                                    // The bubble hangs from the middle of its tail's edge, so its tail stays at the Imp
                                    // whatever height the text comes out.
                                    Color.clear.frame(width: Stroke.hairline, height: Stroke.hairline)
                                        .overlay(alignment: place.alignment) {
                                            SpeechBubble(speech: place.speech, speaker: b.imp, hub: hub, isPocket: pocket.contains(id),
                                                         tailOffset: place.tail, tailEdge: place.edge) {
                                                if pocket.contains(id) { pocket.dismissSpeech(id) } else { hub.dismissSpeech(id) }
                                            }
                                                .fixedSize(horizontal: false, vertical: true)
                                                .transition(.scale(scale: 0.6, anchor: place.unit).combined(with: .opacity))
                                                .id(place.speech.id)
                                        }
                                        .position(place.anchor)
                                        .zIndex(2)
                                }
                            }
                            DoorLabels(engine: engine, frame: date).zIndex(2)
                            GameLayer(engine: engine, date: date, size: geo.size, insets: screen.safeAreaInsets, offersGames: !picking)
                                .zIndex(3)
                        }
                        .impAnimation(ImpDesign.Motion.fade, value: engine.isPlaying)
                        .impAnimation(ImpDesign.Motion.settle, value: hub.speeches.mapValues(\.id))
                        .impAnimation(ImpDesign.Motion.settle, value: pocket.speeches.mapValues(\.id))
                    }

                    if roster.isEmpty && !hub.connectedPeers.isEmpty { EmptyHint(side: .left) }
                }
                .coordinateSpace(name: "stage")
            }
            .ignoresSafeArea()
        }
        // Only a sheet over the whole screen hides the room: under a half sheet the Imps go on living.
        .environment(\.covered, veiled)
        .onAppear { wire() }
        .overlay(alignment: .bottom) {
            PhoneHiddenFloor(imps: floor, watching: scenePhase == .active && !covered && !engine.isBlocking) { bringBack($0) }
                .allowsHitTesting(!floor.isEmpty)
        }
        .overlay(alignment: .bottom) { ShakeReceiptBar(hub: hub).padding(.bottom, Sizing.receiptLift) }
    }

    // MARK: The sheet over the room

    /// The sheet hides the whole room.
    private var veiled: Bool { covered && cover >= 1 }

    /// Calls the Imp the sheet is about into the room left above it, or lets it go when there is no sheet.
    private func call(in size: CGSize, top: CGFloat) {
        guard let guest, let side = engine.bodies[guest]?.size else { return engine.summon(nil, to: nil) }
        engine.summon(guest, to: Summon.point(room: size, top: top, cover: cover, side: side, height: Behavior.summonHeight))
    }

    // MARK: Motion sensor

    /// How often the sensor is read for shakes and throws, or nil when it should be off: while the
    /// app is away, a sheet is over the stage (a shake there is not meant for the Imps) or the phone runs too hot.
    private var motionInterval: TimeInterval? {
        FramePolicy.motionInterval(Energy.shared.conditions(active: scenePhase == .active, visible: !covered, reduceMotion: reduceMotion),
                                   decorative: false)
    }

    // MARK: Shake to send

    /// A deliberate shake: sends the Imp moved last to the device nearby (see `docs/concepts/transfer.md`), or
    /// the Imps get dizzy as they always did when there is nothing to send or nowhere to send it.
    private func shaken(from side: LinkSide?) {
        engine.pacer.wake()
        let settings = ShakeSettings(defaults: .standard)
        let decision: ShakeTransfer.Decision = covered || engine.isBlocking ? .nothing(.off)
            : ShakeTransfer.decide(imps: engine.shakeImps { hub.visit($0) == nil }, peers: hub.shakePeers(),
                                   side: side, settings: settings, now: Date())
        switch decision {
        case .send(let imp, let device):
            sendShaken(imp, to: device, side: side)
        case .ask(let imp, let choices, let why):
            guard let name = engine.bodies[imp]?.imp.name else { return engine.shake() }
            let devices = choices.compactMap { hub.device($0) }
            guard !devices.isEmpty else { return engine.shake() }
            Haptics.notify(.warning)
            asking = ShakeAsk(imp: imp, impName: name, choices: devices, why: why)
        case .nothing:
            engine.shake()
        }
    }

    /// Sends `imp` the way a menu send does (it drifts off the side and the other device answers), and
    /// tells the person what is moving and where. If it cannot go, it stays where it is.
    private func sendShaken(_ id: UUID, to device: UUID, side: LinkSide?) {
        guard let imp = engine.bodies[id]?.imp, engine.sendGently(id, to: device, preferring: side) else { return }
        hub.shakeBegan(imp, to: device)
        Haptics.tap(.medium)
    }

    // MARK: Talk bubbles

    /// Where each talking Imp's bubble goes. Each sits over its Imp's head. One that would land on a
    /// bubble placed before it (in the stage's fixed order, so nothing swaps places as the Imps
    /// float) goes up above that one. A bubble stays put while its Imp floats under it, so its words
    /// hold still to be read.
    /// Where each talk bubble goes. A bubble tries, in turn, over its Imp's head, under it (clear of the name),
    /// and beside it on the side with more room, and takes the first place that is on screen (under the top bar,
    /// above the home indicator and a half sheet) and touches no bubble placed before it. Among places that all
    /// touch something it takes the one that covers least, and one that would leave the screen is moved onto it.
    /// The gap to the Imp is measured from its drawing, so it is the same for every size. A bubble keeps the side
    /// it had while that side still works, so it does not jump as the Imps move.
    private func bubbles(size: CGSize, insets: EdgeInsets, date: Date) -> [UUID: BubblePlace] {
        let top = insets.top + Sizing.hit + Spacing.small
        let bottom = min(size.height - insets.bottom, size.height * (1 - min(max(cover, 0), 1))) - Spacing.small
        let area = CGRect(x: Spacing.medium, y: top, width: size.width - 2 * Spacing.medium, height: max(0, bottom - top))
        let tail = SpeechBubble.tailLength, gap = Spacing.tight
        // Where each Imp is drawn, so a bubble can stay off the others.
        let drawn = engine.bodies.mapValues { b -> CGRect in
            let r = b.size / 2, half = r * ImpRenderer.size.rx / 50
            return CGRect(x: b.pos.x - half, y: b.pos.y - r * StageEngine.reachAbove, width: half * 2, height: r * (StageEngine.reachAbove + StageEngine.reachBelow))
        }
        var placed: [UUID: BubblePlace] = [:]
        var taken: [CGRect] = []
        for id in engine.order {
            guard let b = engine.bodies[id], b.phase == .free || b.phase == .dragging,
                  let speech = hub.speeches[id] ?? pocket.speeches[id], let body = drawn[id] else { continue }
            let (box, isNew) = sizes.size(of: speech)
            if isNew { engine.pacer.wake(at: max(date, Date())) }
            let w = min(box.width, area.width), h = box.height - tail
            let r = b.size / 2
            // The middle of the head, for a bubble beside it.
            let middle = b.pos.y + r * 0.16
            let name: CGFloat = StageLabels.showsWords(playing: engine.isPlaying, menuFor: menuFor, imp: id) ? Spacing.small + Sizing.dot * 3 : 0
            func clampX(_ x: CGFloat) -> CGFloat { min(max(x, area.minX + w / 2), max(area.maxX - w / 2, area.minX + w / 2)) }
            func clampY(_ y: CGFloat) -> CGFloat { min(max(y, area.minY + h / 2), max(area.maxY - h / 2, area.minY + h / 2)) }
            var options: [(edge: Edge, frame: CGRect)] = [
                (.bottom, CGRect(x: clampX(b.pos.x) - w / 2, y: body.minY - gap - tail - h, width: w, height: h)),
                (.top, CGRect(x: clampX(b.pos.x) - w / 2, y: body.maxY + name + gap + tail, width: w, height: h)),
            ]
            let right = (Edge.leading, CGRect(x: body.maxX + gap + tail, y: clampY(middle) - h / 2, width: w, height: h))
            let left = (Edge.trailing, CGRect(x: body.minX - gap - tail - w, y: clampY(middle) - h / 2, width: w, height: h))
            options += b.pos.x < size.width / 2 ? [right, left] : [left, right]
            if let kept = sizes.edge(of: speech.id), let i = options.firstIndex(where: { $0.edge == kept }) {
                options.insert(options.remove(at: i), at: 0)
            }
            func score(_ frame: CGRect) -> CGFloat {
                // Off the screen counts most, then another bubble, then another Imp.
                let off = frame.width * frame.height - Self.overlap(frame, area)
                let bubbles = taken.reduce(0) { $0 + Self.overlap(frame, $1.insetBy(dx: -Spacing.small, dy: -Spacing.small)) }
                let imps = drawn.reduce(0) { $0 + ($1.key == id ? 0 : Self.overlap(frame, $1.value)) }
                return off * 1_000 + bubbles * 10 + imps
            }
            var best = options.min { score($0.frame) < score($1.frame) } ?? options[0]
            if let clean = options.first(where: { score($0.frame) == 0 }) { best = clean }
            // Whatever is left, on the screen.
            var frame = best.frame
            frame.origin.x = min(max(frame.minX, area.minX), max(area.maxX - frame.width, area.minX))
            frame.origin.y = min(max(frame.minY, area.minY), max(area.maxY - frame.height, area.minY))
            taken.append(frame)
            sizes.keep(edge: best.edge, for: speech.id)
            let target: CGPoint = switch best.edge {
            case .bottom: CGPoint(x: b.pos.x, y: body.minY)
            case .top: CGPoint(x: b.pos.x, y: body.maxY)
            case .leading: CGPoint(x: body.maxX, y: middle)
            case .trailing: CGPoint(x: body.minX, y: middle)
            }
            placed[id] = BubblePlace(speech: speech, frame: frame, edge: best.edge, target: target)
        }
        sizes.keep(placed.values.map(\.speech.id))
        return placed
    }

    /// How much of `a` lies in `b`.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    // MARK: One Imp

    /// `talking`: its talk bubble is up, and it already shows that the Imp is thinking or waiting, so the
    /// dots over its head stay away (two sets of dots, one under the other).
    private func figure(_ b: StageEngine.Body, date: Date, talking: Bool = false) -> some View {
        let id = b.imp.id
        let source: any ChatSource = pocket.contains(id) ? pocket : hub
        let awake = source.availability(id) == .ready
        let working = source.working(id)
        let side = b.size
        let dizzy = b.dizzyUntil > date
        let showsWords = StageLabels.showsWords(playing: engine.isPlaying, menuFor: menuFor, imp: id)
        let mood: Mood = {
            if let m = engine.gameMood(b, at: date) { return m }
            if !awake { return .sleepy }
            if dizzy { return .dizzy }
            if b.phase == .dragging { return abs(b.fingerVelocity.dx) > 500 ? .excited : .curious }
            if let m = source.mood(id) { return m }
            return working != nil ? .working : .idle
        }()
        let dots = working != nil && showsWords && !talking
        engine.pacer.note(mood: mood, of: id, awake: awake, animated: dots, at: date)
        let gaze = engine.gaze(for: b)
        return ImpFigure(imp: b.imp, mood: mood, performance: b.performance, lean: b.lean,
                         gaze: gaze.map { Gaze.toward($0.point, from: b.pos) }, attentive: gaze?.attentive ?? false, date: date,
                         bleed: ImpFigure.stageBleed, breathes: awake)
            .frame(width: side, height: side)
            .background {
                // The Imp's own light around it.
                Halo(color: Color.imp(b.imp.hue), opacity: !awake ? 0 : id == guest || picked.contains(id) ? Opacity.glow : Opacity.tintFill)
                    .frame(width: side * 2.3, height: side * 2.3)
            }
            // The dots and the name are placed from the drawing (its horns, its base), not from its square, so they
            // are as close to a big Imp as to a small one. Each hangs from a line of no height at that place.
            .overlay(alignment: .top) {
                if dots {
                    ThinkingDots(date: date)
                        .frame(height: 0, alignment: .bottom)
                        // Above the top of a hop, so the dots never cover the Imp when it jumps.
                        .offset(y: side / 2 * (1 - StageEngine.reachAbove) - Spacing.tight - Spacing.medium)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if showsWords {
                    NameTag(name: b.imp.name)
                        .frame(height: 0, alignment: .top)
                        .offset(y: side / 2 * (1 + StageEngine.reachBelow) + Spacing.small)
                        .opacity(b.phase == .dragging ? Opacity.disabled : 1)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if picking { PickBadge(hue: b.imp.hue, picked: picked.contains(id)).transition(.scale.combined(with: .opacity)) }
            }
            .opacity(awake || engine.isBlocking ? 1 : Opacity.dimmed)
            .contentShape(Circle().inset(by: side * 0.08))
            // A press that holds still starts before the menu does: the bubble goes first. Movement
            // cancels it and the drag takes over, as before. The tap comes after the press in an
            // exclusive pair: the touch that opened the menu never also counts as a tap (a tap has no
            // longest duration, and its end would open the chat over the menu).
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
                    .onEnded { _ in
                        // A press that lingers still counts as a pick while picking, not as a menu.
                        if picking { togglePick(id) } else if !engine.isBlocking { lifted(id) }
                    }
                    .exclusively(before: TapGesture().onEnded {
                        guard !engine.isBlocking, menuImp == nil else { return }
                        menuFor = nil
                        if picking { togglePick(id) } else { onChat(id) }
                    }))
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("stage"))
                .onChanged { menuFor = nil; engine.dragChanged(id, at: $0.location) }
                .onEnded { engine.dragEnded(id, at: $0.location, predicted: $0.predictedEndLocation) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(b.imp.name))
            .accessibilityAddTraits(picking && picked.contains(id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityActions {
                if picking {
                    Button { togglePick(id) } label: { Text(picked.contains(id) ? "phone.select.deselect" : "phone.select.menu") }
                } else {
                    menu(for: b, source: source, awake: awake)
                }
            }
            // It floats while nobody holds it. One that sleeps hangs still.
            .floating(BodyClock(id), reach: Self.floatReach, on: awake && b.phase != .dragging)
            .position(x: b.pos.x, y: b.pos.y)
            .offset(x: b.tiltSlide)
            .zIndex(b.phase == .dragging ? 1 : 0)
    }

    /// How far an Imp floats up and down from its place, in points.
    private static let floatReach: CGFloat = 3.5

    // MARK: Menu

    /// A long press on an Imp: its bubble goes, and its name tag with it, before the menu lifts the Imp.
    private func lifted(_ id: UUID) {
        if pocket.contains(id) { pocket.dismissSpeech(id) } else { hub.dismissSpeech(id) }
        menuFor = id
        // The menu is opened here, by the press itself. The system's own touch-and-hold menu never came
        // up on an Imp, because the drag that carries the Imp took the touch first.
        menuImp = id
        Haptics.tap(.medium)
        Task {
            try? await Task.sleep(for: .seconds(Behavior.toastSeconds))
            if menuFor == id { menuFor = nil }
        }
    }

    /// The Imp's menu, also its VoiceOver actions, in the order of the Mac's: Settings, Select and Hide (about this Imp
    /// here), where it can go (other devices, or home for a visitor), and Goodbye last and apart.
    @ViewBuilder private func menu(for b: StageEngine.Body, source: any ChatSource, awake: Bool) -> some View {
        let id = b.imp.id
        let own = pocket.contains(id)
        Section {
            if own {
                Button { onEdit(id) } label: { Label("menu.imp.settings", systemImage: "slider.horizontal.3") }
            }
            Button { startPicking(with: id) } label: { Label("phone.select.menu", systemImage: "checkmark.circle") }
                .accessibilityIdentifier("imp.select")
            Button { hide(b.imp) } label: { Label("menu.imp.hide", systemImage: "eye.slash") }
        }
        Section {
            ForEach(hub.connectedPeers) { device in
                if hub.way(of: id, to: device.id, preferring: .right) != nil {
                    Button { engine.sendGently(id, to: device.id) } label: {
                        Label(words("menu.imp.send_to", device.name), systemImage: device.kind == .mac ? "macbook" : "iphone")
                    }
                }
            }
            if own {
                ForEach(hub.connectedPeers.filter { $0.kind == .mac }) { mac in
                    Button { moving = (b.imp, mac) } label: { Label(words("menu.imp.move_to", mac.name), systemImage: "macbook.and.iphone") }
                }
            } else {
                Button { hub.sendHome(id) } label: { Label("menu.imp.send_home", systemImage: "house.fill") }
            }
        }
        if own {
            Section {
                Button(role: .destructive) { sayingGoodbye = [b.imp] } label: { Label("menu.imp.goodbye", systemImage: "hand.wave.fill") }
            }
        }
    }

    // MARK: Picking several

    /// The bars over the room while picking, inside the safe area: the room's own top bar steps aside for them.
    @ViewBuilder private var pickingBars: some View {
        if picking {
            VStack(spacing: 0) {
                PickTopBar(count: picked.count, everyone: picked.count >= roster.count, cancel: endPicking, selectAll: pickAll)
                Spacer(minLength: 0).allowsHitTesting(false)
                PickBottomBar(canSendHome: !pickedVisitors.isEmpty, canSayGoodbye: !pickedOwn.isEmpty,
                              hide: hidePicked, sendHome: sendPickedHome, sayGoodbye: askGoodbyeToPicked)
            }
            .transition(.opacity)
        }
    }

    /// Picked Imps in the stage's order, so dialogs and toasts read the same every time.
    private var pickedInOrder: [UUID] { engine.order.filter(picked.contains) }
    /// The picked Imps hatched here, which can say goodbye, and the picked visitors, which can go home.
    private var pickedOwn: [LinkImp] { pickedInOrder.compactMap { id in pocket.contains(id) ? engine.bodies[id]?.imp : nil } }
    private var pickedVisitors: [UUID] { pickedInOrder.filter { !pocket.contains($0) && hub.visit($0) != nil } }

    /// Select in the menu: picking starts with that Imp picked. The Imps keep floating while picking: the engine
    /// has no calm state, and a paused room would also stop the Imps that are being tapped.
    private func startPicking(with id: UUID) {
        picked = [id]
        withAnimation(ImpDesign.Motion.fade.reducedAware(engine.reduceMotion)) { picking = true }
        Haptics.selection()
    }

    private func endPicking() {
        guard picking else { return }
        withAnimation(ImpDesign.Motion.fade.reducedAware(engine.reduceMotion)) { picking = false }
        picked = []
        sayingGoodbye = nil
    }

    /// A tap: picks the Imp or lets it go. With nothing left picked there is nothing to act on, so picking ends.
    private func togglePick(_ id: UUID) {
        picked = ImpPicks.toggle(id, in: picked, selection: nil)
        Haptics.selection()
        if picked.isEmpty { endPicking() }
    }

    private func pickAll() {
        picked = Set(roster.map(\.id))
        Haptics.selection()
    }

    /// An Imp that left the room (sent, said goodbye to, hidden) is no longer picked.
    private func prunePicks() {
        guard picking else { return }
        let here = Set(roster.map(\.id))
        if !picked.isSubset(of: here) { picked.formIntersection(here) }
        if picked.isEmpty { endPicking() }
    }

    private func hidePicked() {
        let imps = pickedInOrder.compactMap { engine.bodies[$0]?.imp }
        guard !imps.isEmpty else { return }
        withAnimation(ImpDesign.Motion.fade.reducedAware(engine.reduceMotion)) { for imp in imps { hidden.hide(imp.id) } }
        hub.toast = imps.count == 1 ? words("imp.hide.undo", imps[0].name) : words("phone.select.hidden", imps.count)
        endPicking()
    }

    private func sendPickedHome() {
        for id in pickedVisitors { hub.sendHome(id) }
        endPicking()
    }

    /// The picked Imps hatched here are asked about once, for all of them.
    private func askGoodbyeToPicked() {
        let imps = pickedOwn
        if !imps.isEmpty { sayingGoodbye = imps }
    }

    /// The ids the goodbye question is about, as the shared dialog takes them.
    private var goodbyeIds: Binding<[UUID]?> {
        Binding(get: { sayingGoodbye?.map(\.id) }, set: { if $0 == nil { sayingGoodbye = nil } })
    }

    // MARK: Wiring

    /// The Imps on this screen: the ones hatched here that are at home, and the visitors.
    private var roster: [LinkImp] { staged.map(\.imp) }
    private var staged: [LinkStaged] { Self.staged(hub, pocket, hidden) }
    private var everyone: [LinkStaged] { Self.everyone(hub, pocket) }
    private var floor: [LinkImp] {
        let ids = hidden.set.onFloor(in: everyone.map(\.imp.id))
        return ids.compactMap { id in everyone.first { $0.imp.id == id }?.imp }
    }

    /// Every Imp this screen could show, hidden or not.
    static func everyone(_ hub: LinkHub, _ pocket: PocketRuntime) -> [LinkStaged] {
        let me = hub.node.device.who
        return pocket.looks.filter { !hub.away.contains($0.id) && !pocket.isMoving($0.id) }.map { LinkStaged(imp: $0, home: me) } + hub.visitors
    }

    private static func staged(_ hub: LinkHub, _ pocket: PocketRuntime, _ hidden: PhoneHidden) -> [LinkStaged] {
        everyone(hub, pocket).filter { !hidden.set.contains($0.imp.id) }
    }

    private func hide(_ imp: LinkImp) {
        withAnimation(ImpDesign.Motion.fade.reducedAware(engine.reduceMotion)) { hidden.hide(imp.id) }
        hub.toast = words("imp.hide.undo", imp.name)
    }

    private func bringBack(_ id: UUID) {
        withAnimation(ImpDesign.Motion.fade.reducedAware(engine.reduceMotion)) { hidden.bringBack(id) }
    }

    /// Hooks the engine to the hub and the pocket Imps (once): events in, tosses and feelings out.
    private func wire() {
        guard !wired else { return }
        wired = true
        let engine = engine, hub = hub, pocket = pocket, hidden = hidden
        let activity = $activity
        engine.pacer.onChange = { activity.wrappedValue = $0 }
        motion.onTilt = { engine.pacer.wake() }
        hub.isPlaying = { engine.isBlocking }
        engine.door = { hub.door(of: $0, side: $1, height: $2) }
        engine.way = { hub.way(of: $0, to: $1, preferring: $2) }
        engine.doors = { hub.doors(of: $0, side: $1) }
        engine.hint = { hub.hint(for: $0, bounce: $1, side: $2) }
        engine.send = { id, exit in
            guard let device = exit.to, let imp = engine.bodies[id]?.imp else { return }
            if exit.moves {
                pocket.move(id, exit: exit, to: device)
                Haptics.tap(.rigid, intensity: 0.7)
            } else if hub.pass(imp, exit: exit, to: device) {
                // Off to another device: a light tap as it goes.
                Haptics.tap(.rigid, intensity: 0.7)
            } else {
                hub.shakeFailed(id)
                engine.refused(id, words("phone.stage.not_around", hub.deviceName(device)))
                Haptics.notify(.warning)
            }
        }
        engine.warn = { hub.toast = $0 }
        engine.felt = { if !pocket.contains($0) { hub.felt($0, $1) } }
        let hear: (StageEvent) -> Void = { event in
            switch event {
            case .roster: engine.reconcile(Self.staged(hub, pocket, hidden).map(\.imp))
            case .arrived(let imp, let entry):
                engine.arrive(imp, entry)
                // An Imp lands here from another device: you feel it come in.
                Haptics.tap(.medium)
            case .left(let id):
                engine.leave(id)
                Haptics.tap(.light, intensity: 0.6)
            case .refused(let id, let why):
                engine.refused(id, why)
                Haptics.notify(.warning)
            case .animate(let id, let act): engine.animate(id, act)
            }
        }
        hub.onEvent = hear
        pocket.onEvent = hear
        motion.onEvent = { event in
            switch event {
            case .thrown(let side): engine.jolt(side)
            case .shaken: shaken(from: motion.shakeStart)
            }
        }
        engine.reconcile(roster)
        hub.setStage(staged)
    }
}

/// A small tag under an Imp.
private struct NameTag: View {
    var name: String
    var body: some View {
        Text(name)
            .font(Typeface.small.weight(.semibold))
            .foregroundStyle(Tone.paper)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, Spacing.small).padding(.vertical, Spacing.hairline)
            .background(Tone.scrim, in: Capsule())
            .frame(maxWidth: Sizing.doorLabel)
            .allowsHitTesting(false)
    }
}

/// Three dots bouncing above an Imp that's working on something.
/// It bounces with the stage's own clock, so it costs no timeline of its own.
private struct ThinkingDots: View {
    var date: Date

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        HStack(spacing: Spacing.tight) {
            ForEach(0..<3, id: \.self) { i in
                // White on the scrim, in both themes: the dark dots were lost on the light stage.
                Circle().fill(Tone.paper).frame(width: Spacing.snug, height: Spacing.snug)
                    .offset(y: -Spacing.tight * max(0, sin(t * 6 - Double(i) * 0.9)))
            }
        }
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.snug)
        .background(Tone.scrim, in: Capsule())
        .allowsHitTesting(false)
    }
}

/// Shown when another device is there and nothing is on the phone yet.
struct EmptyHint: View {
    var side: LinkSide
    @State private var go = false

    var body: some View {
        VStack(spacing: Spacing.roomy) {
            ZStack {
                Image(systemName: "macbook.and.iphone")
                    .font(.icon(.huge, weight: .light))
                    .foregroundStyle(Tone.accent)
                // A little arrow slides in from the side once, the way an Imp would, and stays: a hint that loops costs frames for nothing.
                Image(systemName: "arrow.right")
                    .font(.icon(.big, weight: .bold))
                    .foregroundStyle(Tone.accentBright)
                    .offset(x: go ? Sizing.tipWidth * 0.3 : -Sizing.tipWidth * 0.6)
                    .opacity(go ? 0 : 1)
                    .impAnimation(ImpDesign.Motion.fade, value: go)
            }
            .frame(width: Sizing.tipWidth, height: Sizing.marker + Spacing.page)
            .clipped()
            Text("phone.stage.throw_hint")
                .font(Typeface.body)
                .foregroundStyle(Tone.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Sizing.popoverWidth)
        }
        .padding(Spacing.wide)
        .onAppear { go = true }
        .allowsHitTesting(false)
    }
}

/// The phone's own motion: a throw of the whole phone, or a shake. Read from the shared `TiltSource`
/// (one motion manager for the whole app), and only an event comes back to the stage.
@MainActor
final class MotionWatcher {
    private var jolts = JoltDetector()
    private var applied: (threshold: Double, pushes: Int)?
    var onEvent: ((JoltDetector.Event) -> Void)?
    /// The phone was tipped further than `tiltStep` since the last report: the stage has to draw frames to follow it.
    var onTilt: (() -> Void)?
    private var reportedTilt = 0.0
    private static let tiltStep = 0.02
    /// The way the last shake began.
    var shakeStart: LinkSide? { jolts.shakeStart }

    /// Applies the shake settings (how hard a shake has to be).
    func configure() {
        let sensitivity = ShakeSettings(defaults: .standard).sensitivity
        guard applied?.threshold != sensitivity.threshold || applied?.pushes != sensitivity.pushes else { return }
        applied = (sensitivity.threshold, sensitivity.pushes)
        jolts = JoltDetector(threshold: sensitivity.threshold, shakeCount: sensitivity.pushes)
    }

    /// How far the phone is tipped to the side (-1...1, right is positive), while its motion is followed.
    var tilt: Double { following ? TiltSource.shared.gravity.x : 0 }
    private var following = false

    func start(interval: TimeInterval) {
        configure()
        following = true
        TiltSource.shared.attach(self, interval: interval) { [weak self] a, t in
            guard let self else { return }
            // The tilt: an idle stage draws no frames, so a tilt has to wake it (the Imps are moved on each frame).
            let tilt = TiltSource.shared.gravity.x
            if abs(tilt - reportedTilt) > Self.tiltStep {
                reportedTilt = tilt
                onTilt?()
            }
            // The turn too: a flick of the wrist is told by it far better than by the push alone.
            guard let event = jolts.feed(x: a.x, spin: TiltSource.shared.spin, at: t) else { return }
            onEvent?(event)
        }
    }

    func stop() {
        following = false
        TiltSource.shared.detach(self)
    }
}
