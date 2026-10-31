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
                .preferredColorScheme(.dark)
                .tint(Dungeon.ember)
                .onOpenURL { url in
                    // A link to join opened from the Camera app (or Notes, Messages…).
                    if !hub.join(code: url.absoluteString) { hub.toast = String(localized: "That isn't a link from Imp.") }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in hub.setActive(phase == .active) }
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
        case talks(UUID)
        case pair

        var id: Self { self }
        var isChat: Bool { if case .chat = self { true } else { false } }
    }

    let hub: LinkHub
    let pocket: PocketRuntime
    @State private var sheet: Sheet?
    @State private var forgetting: LinkDevice?
    /// A round of Embers is on (see `EmbersPlaying`).
    @State private var playing = false
    @State private var toast: String?

    private var onStage: Bool { !hub.links.isEmpty || !hub.visits.isEmpty || !pocket.imps.isEmpty }

    var body: some View {
        ZStack {
            DungeonBackdrop()
            if !onStage {
                PairingView(hub: hub) { sheet = .hatch }
                    .transition(.opacity)
            } else {
                PhoneStage(hub: hub, pocket: pocket, onChat: { sheet = .chat($0) }, onEdit: { sheet = .edit($0) }, onTalks: { sheet = .talks($0) })
                    .transition(.opacity)
                    .onPreferenceChange(EmbersPlaying.self) { playing = $0 }
                VStack {
                    StatusPill(hub: hub, pocket: pocket, forgetting: $forgetting, hatch: { sheet = .hatch }, pair: { sheet = .pair })
                    Spacer()
                }
                .padding(.top, 6)
                .opacity(playing ? 0 : 1)
                .offset(y: playing ? -12 : 0)
                .allowsHitTesting(!playing)
                .animation(.spring(duration: 0.4), value: playing)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onStage)
        .overlay(alignment: .bottom) { ToastView(text: toast).padding(.bottom, 28) }
        .onChange(of: hub.toast) { _, text in
            guard let text else { return }
            toast = text
            hub.toast = nil
            Task {
                try? await Task.sleep(for: .seconds(2.8))
                if toast == text { toast = nil }
            }
        }
        .onChange(of: hub.links.count) { old, new in
            if new > old, sheet == .pair { sheet = nil }
        }
        .sheet(item: $sheet) { route in
            content(route)
                .presentationDetents(route.isChat ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Dungeon.deep)
        }
        .confirmationDialog(forgetting.map { String(localized: "Forget \($0.name)?") } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { device in
            Button("Forget", role: .destructive) { hub.forget(device.id) }
        } message: { _ in
            Text("Imps of this iPhone it holds come home, and its Imps visiting here go home. You can link again any time.")
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

    @ViewBuilder private func content(_ route: Sheet) -> some View {
        switch route {
        case .chat(let id):
            if pocket.contains(id) {
                ChatSheet(hub: hub, source: pocket, pocket: pocket, impID: id) { sheet = .edit(id) }
            } else {
                ChatSheet(hub: hub, source: hub, pocket: pocket, impID: id)
            }
        case .talks(let id):
            TalksSheet(hub: hub, pocket: pocket, impID: id)
        case .hatch:
            PocketEditor(pocket: pocket, editing: nil) { sheet = nil }
        case .edit(let id):
            PocketEditor(pocket: pocket, editing: id) { sheet = pocket.contains(id) ? .chat(id) : nil }
        case .pair:
            ZStack {
                DungeonBackdrop()
                PairingView(hub: hub)
            }
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
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(Dungeon.cream)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Dungeon.cardEdge))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4), value: text)
    }
}
