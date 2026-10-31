import CoreMotion
import ImpKit
import SwiftUI

/// The phone's room: Imps floating in the dungeon, to drag, toss, tap and shake.
struct PhoneStage: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    var onChat: (UUID) -> Void
    /// Opens an Imp hatched here in the editor.
    var onEdit: (UUID) -> Void = { _ in }
    /// Opens what the Imp said with other Imps.
    var onTalks: (UUID) -> Void = { _ in }
    /// An Imp hatched here, waiting for "Delete" to be confirmed.
    @State private var deleting: LinkImp?
    @State private var engine = StageEngine()
    @State private var motion = MotionWatcher()
    @State private var sizes = BubbleSizes()
    /// How fast the stage is drawn right now (the engine says, see `StagePacer`).
    @State private var pace = StagePace.lively
    @Environment(\.scenePhase) private var scenePhase
    @State private var wired = false

    var body: some View {
        // The stage runs edge to edge, so the screen's safe area (notch, Dynamic Island, home
        // indicator) is measured outside it, for what has to stay clear of them.
        GeometryReader { screen in
            GeometryReader { geo in
                ZStack {
                    // Touches that miss every Imp still make them look.
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                            .onChanged { engine.touch = $0.location; engine.pacer.wake() }
                            .onEnded { _ in engine.touch = nil })

                    TimelineView(Energy.shared.schedule(lively: pace == .lively, paused: scenePhase != .active || pace == .idle)) { timeline in
                        let _ = engine.step(timeline.date, size: geo.size, insets: geo.safeAreaInsets)
                        ZStack {
                            EchoFloor(engine: engine, date: timeline.date, reduceMotion: engine.reduceMotion)
                            ForEach(engine.order, id: \.self) { id in
                                if let body = engine.bodies[id] {
                                    figure(body, date: timeline.date)
                                }
                            }
                            // Talks with other Imps, above the talker's head, kept on screen.
                            let places = bubbles(size: geo.size, date: timeline.date)
                            ForEach(engine.order, id: \.self) { id in
                                if let b = engine.bodies[id], let place = places[id] {
                                    Color.clear.frame(width: 1, height: 1)
                                        .overlay(alignment: .bottom) {
                                            SpeechBubble(speech: place.speech, speaker: b.imp, hub: hub, isPocket: pocket.contains(id), tailOffset: b.pos.x - place.x) {
                                                if pocket.contains(id) { pocket.dismissSpeech(id) } else { hub.dismissSpeech(id) }
                                            }
                                                .fixedSize(horizontal: false, vertical: true)
                                                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                                                .id(place.speech.id)
                                        }
                                        .position(x: place.x, y: place.top + engine.floatOffset(b, at: timeline.date, calm: false))
                                        .zIndex(2)
                                }
                            }
                            GameLayer(engine: engine, date: timeline.date, size: geo.size, insets: screen.safeAreaInsets)
                                .zIndex(3)
                        }
                        .animation(.spring(duration: 0.35), value: hub.speeches.mapValues(\.id))
                        .animation(.spring(duration: 0.35), value: pocket.speeches.mapValues(\.id))
                    }

                    if roster.isEmpty && !hub.connectedPeers.isEmpty { EmptyHint(side: .left) }
                }
                .coordinateSpace(name: "stage")
            }
            .ignoresSafeArea()
        }
        .onAppear { wire() }
        .confirmationDialog(deleting.map { String(localized: "Delete \($0.name)?") } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { imp in
            Button("Delete", role: .destructive) { pocket.delete(imp.id) }
        } message: { _ in
            Text("Its chats and keys are forgotten. This can't be undone.")
        }
        .onChange(of: staged) {
            engine.reconcile(roster)
            hub.setStage(staged)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { motion.start() } else { motion.stop() }
            // A voice doesn't go on talking from a phone that's been put away.
            if phase == .background { StageVoice.shared.interrupt() }
        }
    }

    // MARK: Talk bubbles

    /// Where each talking Imp's bubble goes. Each sits over its Imp's head; one that would land on a
    /// bubble placed before it (in the stage's fixed order, so nothing swaps places as the Imps
    /// float) goes up above that one. Floating isn't counted, so nothing jitters.
    private func bubbles(size: CGSize, date: Date) -> [UUID: (speech: LinkSpeech, x: CGFloat, top: CGFloat)] {
        var placed: [UUID: (speech: LinkSpeech, x: CGFloat, top: CGFloat)] = [:]
        var frames: [CGRect] = []
        for id in engine.order {
            guard let b = engine.bodies[id], b.phase == .free || b.phase == .dragging,
                  let speech = hub.speeches[id] ?? pocket.speeches[id] else { continue }
            let (box, isNew) = sizes.size(of: speech)
            if isNew { engine.pacer.wake(at: date) }
            let x = min(max(b.pos.x, box.width / 2 + 12), max(size.width - box.width / 2 - 12, box.width / 2 + 12))
            var top = b.pos.y - b.size * 0.4 - 14
            var frame = CGRect(x: x - box.width / 2, y: top - box.height, width: box.width, height: box.height)
            for other in frames.sorted(by: { $0.minY > $1.minY }) where frame.insetBy(dx: -4, dy: -6).intersects(other) {
                top = other.minY - 8
                frame.origin.y = top - box.height
            }
            frames.append(frame)
            placed[id] = (speech, x, top)
        }
        sizes.keep(placed.values.map(\.speech.id))
        return placed
    }

    // MARK: One Imp

    private func figure(_ b: StageEngine.Body, date: Date) -> some View {
        let id = b.imp.id
        let source: any ChatSource = pocket.contains(id) ? pocket : hub
        let awake = source.availability(id) == .ready
        let working = source.working(id)
        let side = b.size
        let dizzy = b.dizzyUntil > date
        let mood: Mood = {
            if let m = engine.gameMood(b, at: date) { return m }
            if !awake { return .sleepy }
            if dizzy { return .dizzy }
            if b.phase == .dragging { return abs(b.fingerVelocity.dx) > 500 ? .excited : .curious }
            if let m = source.mood(id) { return m }
            return working != nil ? .working : .idle
        }()
        engine.pacer.note(mood: mood, of: id, at: date)
        let gaze = engine.gaze(for: b)
        return ImpFigure(imp: b.imp, mood: mood, performance: b.performance, lean: b.lean,
                         gaze: gaze.map { Gaze.toward($0.point, from: b.pos) }, attentive: gaze?.attentive ?? false, date: date)
            .frame(width: side, height: side)
            .background {
                // Warm light around it, so it glows against the wall.
                SoftGlow(color: Dungeon.ember, opacity: awake ? 0.16 : 0.05)
                    .frame(width: side * 2.3, height: side * 2.3)
            }
            .overlay(alignment: .top) {
                if working != nil { ThinkingDots(date: date).offset(y: -side * 0.12).transition(.scale.combined(with: .opacity)) }
            }
            .overlay(alignment: .bottom) {
                NameTag(name: b.imp.name).offset(y: 14).opacity(b.phase == .dragging ? 0.4 : 1)
            }
            .opacity(awake || engine.isPlaying ? 1 : 0.7)
            .contentShape(Circle().inset(by: side * 0.08))
            .onTapGesture { if !engine.isPlaying { onChat(id) } }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("stage"))
                .onChanged { engine.dragChanged(id, at: $0.location) }
                .onEnded { engine.dragEnded(id, at: $0.location, predicted: $0.predictedEndLocation) })
            .contextMenu {
                Button { onChat(id) } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                Button { source.newChat(id); onChat(id) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                Button { onTalks(id) } label: { Label("Talks", systemImage: "bubble.left.and.bubble.right") }
                if pocket.contains(id) {
                    Button { onEdit(id) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                }
                ForEach(hub.connectedPeers) { device in
                    if hub.way(of: id, to: device.id, preferring: .right) != nil {
                        Button { engine.sendGently(id, to: device.id) } label: {
                            Label("Send to \(device.name)", systemImage: device.kind == .mac ? "macbook" : "iphone")
                        }
                    }
                }
                if pocket.contains(id) {
                    ForEach(hub.connectedPeers.filter { $0.kind == .mac }) { mac in
                        Button { engine.sendGently(id, to: mac.id, moves: true) } label: {
                            Label("Move to \(mac.name)", systemImage: "macbook.and.iphone")
                        }
                    }
                    Button(role: .destructive) { deleting = b.imp } label: { Label("Delete", systemImage: "trash") }
                } else {
                    Button(role: .destructive) { hub.sendHome(id) } label: { Label("Send Home", systemImage: "house") }
                }
            }
            .position(x: b.pos.x, y: b.pos.y + engine.floatOffset(b, at: date, calm: !awake))
            .zIndex(b.phase == .dragging ? 1 : 0)
    }

    // MARK: Wiring

    /// The Imps on this screen: the ones hatched here that are at home, and the visitors.
    private var roster: [LinkImp] { staged.map(\.imp) }
    private var staged: [LinkStaged] { Self.staged(hub, pocket) }

    private static func staged(_ hub: LinkHub, _ pocket: PocketRuntime) -> [LinkStaged] {
        let me = hub.node.device.id
        return pocket.looks.filter { !hub.away.contains($0.id) }.map { LinkStaged(imp: $0, home: me) } + hub.visitors
    }

    /// Hooks the engine to the hub and the pocket Imps (once): events in, tosses and feelings out.
    private func wire() {
        guard !wired else { return }
        wired = true
        let engine = engine, hub = hub, pocket = pocket
        let pace = $pace
        engine.pacer.onChange = { pace.wrappedValue = $0 }
        hub.isPlaying = { engine.isPlaying }
        engine.isConnected = { !hub.connectedPeers.isEmpty }
        engine.door = { hub.door(of: $0, side: $1, height: $2) }
        engine.way = { hub.way(of: $0, to: $1, preferring: $2) }
        engine.hint = { hub.hint(for: $0, bounce: $1, side: $2) }
        engine.send = { id, exit in
            guard let device = exit.to, let imp = engine.bodies[id]?.imp else { return }
            if exit.moves {
                pocket.move(id, exit: exit, to: device)
            } else if !hub.pass(imp, exit: exit, to: device) {
                engine.refused(id, String(localized: "\(hub.deviceName(device)) isn't around"))
            }
        }
        engine.warn = { hub.toast = $0 }
        engine.felt = { if !pocket.contains($0) { hub.felt($0, $1) } }
        let hear: (StageEvent) -> Void = { event in
            switch event {
            case .roster: engine.reconcile(Self.staged(hub, pocket).map(\.imp))
            case .arrived(let imp, let entry): engine.arrive(imp, entry)
            case .left(let id): engine.leave(id)
            case .refused(let id, let why): engine.refused(id, why)
            case .animate(let id, let beats): engine.animate(id, beats)
            }
        }
        hub.onEvent = hear
        pocket.onEvent = hear
        motion.onEvent = { event in
            switch event {
            case .thrown(let side): engine.jolt(side)
            case .shaken: engine.shake(); engine.pacer.wake()
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
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Dungeon.cream.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.black.opacity(0.28), in: Capsule())
            .allowsHitTesting(false)
    }
}

/// Three dots bouncing above an Imp that's working on something.
/// It bounces with the stage's own clock, so it costs no timeline of its own.
private struct ThinkingDots: View {
    var date: Date

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Dungeon.flame).frame(width: 5, height: 5)
                    .offset(y: -3 * max(0, sin(t * 6 - Double(i) * 0.9)))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.black.opacity(0.35), in: Capsule())
        .allowsHitTesting(false)
    }
}

/// Shown when another device is there and nothing is on the phone yet.
struct EmptyHint: View {
    var side: LinkSide
    @State private var go = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Dungeon.ember.opacity(0.85))
                // A little arrow sliding in from the side, the way an Imp would.
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Dungeon.flame)
                    .offset(x: go ? 70 : -150)
                    .opacity(go ? 0 : 1)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: go)
            }
            .frame(width: 220, height: 70)
            .clipped()
            Text("Throw an Imp off the side of another screen — it lands here.")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(24)
        .onAppear { go = true }
        .allowsHitTesting(false)
    }
}

/// The phone's own motion: a throw of the whole phone, or a shake. Sampled off the main queue (only
/// an event comes back to it), and no faster than a jolt needs: a throw lasts a tenth of a second.
@MainActor
final class MotionWatcher {
    /// Samples a second.
    nonisolated static let rate = 50.0

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.imp.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    var onEvent: ((JoltDetector.Event) -> Void)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        let sampler = JoltSampler { [weak self] event in
            Task { @MainActor in self?.onEvent?(event) }
        }
        manager.deviceMotionUpdateInterval = 1 / Self.rate
        manager.startDeviceMotionUpdates(to: queue) { data, _ in
            guard let data else { return }
            sampler.feed(x: data.userAcceleration.x, at: data.timestamp)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Feeds the jolt detector from the motion queue (one at a time, so it needs no lock).
private final class JoltSampler: @unchecked Sendable {
    private var jolts = JoltDetector()
    private let onEvent: @Sendable (JoltDetector.Event) -> Void

    init(onEvent: @escaping @Sendable (JoltDetector.Event) -> Void) { self.onEvent = onEvent }

    func feed(x: Double, at t: TimeInterval) {
        if let event = jolts.feed(x: x, at: t) { onEvent(event) }
    }
}
