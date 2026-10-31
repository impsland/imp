import ImpKit
import SwiftUI

@main
struct ImpPhoneApp: App {
    @State private var client: LinkClient
    @State private var pocket: PocketRuntime
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let client = LinkClient()
        #if DEBUG
        // Screenshots and demos without a Mac: `-demo` fills the stage with a few Imps.
        if CommandLine.arguments.contains("-demo") { client.loadDemo() }
        // End-to-end checks against a real Mac in the Simulator: `-pair <implink://…>` pairs at launch.
        if let i = CommandLine.arguments.firstIndex(of: "-pair"), CommandLine.arguments.indices.contains(i + 1),
           let pairing = LinkPairing(string: CommandLine.arguments[i + 1]) {
            client.pair(pairing)
        }
        #endif
        _client = State(initialValue: client)
        _pocket = State(initialValue: PocketRuntime(client: client))
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client, pocket: pocket)
                .preferredColorScheme(.dark)
                .tint(Dungeon.ember)
                .onOpenURL { url in
                    // A pairing link opened from the Camera app (or Notes, Messages…).
                    if let pairing = LinkPairing(url: url) { client.pair(pairing) }
                    else { client.toast = String(localized: "That isn't a pairing link from Imp.") }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in client.setActive(phase == .active) }
        }
    }
}

/// Pairing when there's nothing yet; the stage once there's a Mac or an Imp hatched on this iPhone.
struct RootView: View {
    /// What's in the sheet.
    private enum Sheet: Hashable, Identifiable {
        case chat(UUID)
        case hatch
        case edit(UUID)
        case pair

        var id: Self { self }
        var isChat: Bool { if case .chat = self { true } else { false } }
    }

    let client: LinkClient
    let pocket: PocketRuntime
    @State private var sheet: Sheet?
    @State private var confirmUnpair = false
    /// A round of Embers is on (see `EmbersPlaying`).
    @State private var playing = false
    @State private var toast: String?

    private var onStage: Bool { client.pairing != nil || !pocket.imps.isEmpty }

    var body: some View {
        ZStack {
            DungeonBackdrop()
            if !onStage {
                PairingView(client: client) { sheet = .hatch }
                    .transition(.opacity)
            } else {
                PhoneStage(client: client, pocket: pocket) { sheet = .chat($0) }
                    .transition(.opacity)
                    .onPreferenceChange(EmbersPlaying.self) { playing = $0 }
                VStack {
                    StatusPill(client: client, confirmUnpair: $confirmUnpair, hatch: { sheet = .hatch }, pair: { sheet = .pair })
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
        .onChange(of: client.toast) { _, text in
            guard let text else { return }
            toast = text
            client.toast = nil
            Task {
                try? await Task.sleep(for: .seconds(2.8))
                if toast == text { toast = nil }
            }
        }
        .onChange(of: client.pairing != nil) { _, paired in
            if paired, sheet == .pair { sheet = nil }
        }
        .sheet(item: $sheet) { route in
            content(route)
                .presentationDetents(route.isChat ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Dungeon.deep)
        }
        .confirmationDialog("Unpair from \(client.macName ?? "Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("The Imps on this phone stay with your Mac. You can pair again any time.")
        }
        #if DEBUG
        .task {
            if CommandLine.arguments.contains("-hatch") { sheet = .hatch }
            if CommandLine.arguments.contains("-openChat") {
                // Waits for the Imps (from the demo, or from a Mac it's connecting to).
                for _ in 0..<120 where client.imps.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(1.5))
                if let first = client.imps.first { sheet = .chat(first.id) }
            }
            // `-ask <text>`: once connected, asks the first Imp and opens its chat (end-to-end checks).
            if let i = CommandLine.arguments.firstIndex(of: "-ask"), CommandLine.arguments.indices.contains(i + 1) {
                for _ in 0..<120 where !(client.isConnected && !client.imps.isEmpty) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let first = client.imps.first else { return }
                client.ask(first.id, CommandLine.arguments[i + 1])
                sheet = .chat(first.id)
            }
        }
        #endif
    }

    @ViewBuilder private func content(_ route: Sheet) -> some View {
        switch route {
        case .chat(let id):
            if pocket.contains(id) {
                ChatSheet(client: client, source: pocket, impID: id) { sheet = .edit(id) }
            } else {
                ChatSheet(client: client, source: client, impID: id)
            }
        case .hatch:
            PocketEditor(pocket: pocket, editing: nil) { sheet = nil }
        case .edit(let id):
            PocketEditor(pocket: pocket, editing: id) { sheet = pocket.contains(id) ? .chat(id) : nil }
        case .pair:
            ZStack {
                DungeonBackdrop()
                PairingView(client: client)
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
