import CoreMotion
import ImpKit
import SwiftUI

/// The phone's room: Imps floating in the dungeon, to drag, toss, tap and shake.
struct PhoneStage: View {
    let client: LinkClient
    var onChat: (UUID) -> Void
    @State private var engine = StageEngine()
    @State private var motion = MotionWatcher()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wired = false

    var body: some View {
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
                    }
                }

                if client.imps.isEmpty && client.isConnected { EmptyHint(side: .left) }
            }
            .coordinateSpace(name: "stage")
        }
        .ignoresSafeArea()
        .onAppear { wire() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { motion.start() } else { motion.stop() }
        }
    }

    // MARK: One Imp

    private func figure(_ b: StageEngine.Body, date: Date) -> some View {
        let id = b.imp.id
        let connected = client.isConnected
        let working = client.work[id]
        let side = b.size
        let dizzy = b.dizzyUntil > date
        let mood: Mood = {
            if !connected { return .sleepy }
            if dizzy { return .dizzy }
            if b.phase == .dragging { return abs(b.fingerVelocity.dx) > 500 ? .excited : .curious }
            if let m = client.moods[id] { return m }
            return working != nil ? .working : .idle
        }()
        let gaze = engine.gaze(for: b)
        return ImpFigure(imp: b.imp, mood: mood, performance: b.performance, lean: b.lean,
                         gaze: gaze.map { Gaze.toward($0.point, from: b.pos) }, attentive: gaze?.attentive ?? false, date: date)
            .frame(width: side, height: side)
            .background {
                // Warm light around it, so it glows against the wall.
                SoftGlow(color: Dungeon.ember, opacity: connected ? 0.16 : 0.05)
                    .frame(width: side * 2.3, height: side * 2.3)
            }
            .overlay(alignment: .top) {
                if working != nil { ThinkingDots().offset(y: -side * 0.12).transition(.scale.combined(with: .opacity)) }
            }
            .overlay(alignment: .bottom) {
                NameTag(name: b.imp.name).offset(y: 14).opacity(b.phase == .dragging ? 0.4 : 1)
            }
            .opacity(connected ? 1 : 0.7)
            .contentShape(Circle().inset(by: side * 0.08))
            .onTapGesture { onChat(id) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("stage"))
                .onChanged { engine.dragChanged(id, at: $0.location) }
                .onEnded { engine.dragEnded(id, at: $0.location, predicted: $0.predictedEndLocation) })
            .contextMenu {
                Button { onChat(id) } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                Button { client.newChat(id); onChat(id) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                Button { engine.sendGently(id) } label: { Label("Send to Mac", systemImage: "macbook.and.iphone") }
            }
            .position(x: b.pos.x, y: b.pos.y + engine.floatOffset(b, at: date, calm: !connected))
            .zIndex(b.phase == .dragging ? 1 : 0)
    }

    // MARK: Wiring

    /// Hooks the engine to the client (once): events from the Mac in, tosses and feelings out.
    private func wire() {
        guard !wired else { return }
        wired = true
        let engine = engine, client = client
        engine.isConnected = { client.isConnected }
        engine.send = { id, side, height, speed in client.toss(id, exit: side, height: height, speed: speed) }
        engine.warn = { client.toast = $0 }
        engine.felt = { client.felt($0, $1) }
        client.onEvent = { event in
            switch event {
            case .roster(let imps): engine.reconcile(imps)
            case .arrived(let imp, let entry): engine.arrive(imp, entry)
            case .left(let id): engine.leave(id)
            case .refused(let id, let why): engine.refused(id, why)
            case .animate(let id, let beats): engine.animate(id, beats)
            }
        }
        motion.onEvent = { event in
            switch event {
            case .thrown(let side): engine.jolt(side)
            case .shaken: engine.shake()
            }
        }
        engine.reconcile(client.imps)
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
