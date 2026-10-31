import CoreMotion
import ImpKit
import SwiftUI

/// The phone's room: Imps floating in the dungeon, to drag, toss, tap and shake.
struct PhoneStage: View {
    let client: LinkClient
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
                            .onChanged { engine.touch = $0.location }
                            .onEnded { _ in engine.touch = nil })

                    TimelineView(.animation(paused: scenePhase != .active)) { timeline in
                        let _ = engine.step(timeline.date, size: geo.size, insets: geo.safeAreaInsets)
                        ZStack {
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
                                            SpeechBubble(speech: place.speech, speaker: b.imp, client: client, isPocket: pocket.contains(id), tailOffset: b.pos.x - place.x) {
                                                if pocket.contains(id) { pocket.dismissSpeech(id) } else { client.dismissSpeech(id) }
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
                        .animation(.spring(duration: 0.35), value: client.speeches.mapValues(\.id))
                        .animation(.spring(duration: 0.35), value: pocket.speeches.mapValues(\.id))
                    }

                    if roster.isEmpty && client.isConnected { EmptyHint(side: .left) }
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
        .onChange(of: pocket.looks) { engine.reconcile(roster) }
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
                  let speech = client.speeches[id] ?? pocket.speeches[id] else { continue }
            let box = SpeechBubble.size(of: speech)
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
        return placed
    }

    // MARK: One Imp

    private func figure(_ b: StageEngine.Body, date: Date) -> some View {
        let id = b.imp.id
        let source: any ChatSource = pocket.contains(id) ? pocket : client
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
                if working != nil { ThinkingDots().offset(y: -side * 0.12).transition(.scale.combined(with: .opacity)) }
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
                if client.pairing != nil {
                    Button { engine.sendGently(id) } label: { Label("Send to Mac", systemImage: "macbook.and.iphone") }
                }
                if pocket.contains(id) {
                    Button(role: .destructive) { deleting = b.imp } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .position(x: b.pos.x, y: b.pos.y + engine.floatOffset(b, at: date, calm: !awake))
            .zIndex(b.phase == .dragging ? 1 : 0)
    }

    // MARK: Wiring

    /// The Imps on this phone: the Mac's, and the ones hatched here.
    private var roster: [LinkImp] { Self.roster(client, pocket) }

    private static func roster(_ client: LinkClient, _ pocket: PocketRuntime) -> [LinkImp] {
        client.imps + pocket.looks.filter { look in !client.imps.contains { $0.id == look.id } }
    }

    /// Hooks the engine to the client and the pocket Imps (once): events in, tosses and feelings out.
    private func wire() {
        guard !wired else { return }
        wired = true
        let engine = engine, client = client, pocket = pocket
        engine.isConnected = { client.isConnected }
        engine.send = { id, side, height, speed in
            if pocket.contains(id) { pocket.toss(id, exit: side, height: height, speed: speed) }
            else { client.toss(id, exit: side, height: height, speed: speed) }
        }
        engine.warn = { client.toast = $0 }
        engine.felt = { if !pocket.contains($0) { client.felt($0, $1) } }
        let hear: (StageEvent) -> Void = { event in
            switch event {
            case .roster: engine.reconcile(Self.roster(client, pocket))
            case .arrived(let imp, let entry): engine.arrive(imp, entry)
            case .left(let id): engine.leave(id)
            case .refused(let id, let why): engine.refused(id, why)
            case .animate(let id, let beats): engine.animate(id, beats)
            }
        }
        client.onEvent = hear
        pocket.onEvent = hear
        motion.onEvent = { event in
            switch event {
            case .thrown(let side): engine.jolt(side)
            case .shaken: engine.shake()
            }
        }
        engine.reconcile(roster)
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
private struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Dungeon.flame).frame(width: 5, height: 5)
                        .offset(y: -3 * max(0, sin(t * 6 - Double(i) * 0.9)))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.black.opacity(0.35), in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

/// Shown when the Mac is there and nothing is on the phone yet.
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
            Text("Throw an Imp off the side of your Mac's screen — it lands here.")
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

/// The phone's own motion: a throw of the whole phone, or a shake.
@MainActor
final class MotionWatcher {
    private let manager = CMMotionManager()
    private var jolts = JoltDetector()
    var onEvent: ((JoltDetector.Event) -> Void)?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        jolts = JoltDetector()
        manager.deviceMotionUpdateInterval = 1 / 60
        manager.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            let x = data.userAcceleration.x, t = data.timestamp
            MainActor.assumeIsolated {
                guard let self, let event = self.jolts.feed(x: x, at: t) else { return }
                self.onEvent?(event)
            }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}
