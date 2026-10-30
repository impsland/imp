import ImpKit
import SwiftUI

@main
struct ImpPhoneApp: App {
    @State private var client = LinkClient()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Screenshots and demos without a Mac: `-demo` fills the stage with a few Imps.
        if let i = CommandLine.arguments.firstIndex(of: "-renderIcon"), CommandLine.arguments.indices.contains(i + 1) {
            IconRender.run(to: CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("-demo") { _client = State(initialValue: Self.demoClient()) }
        // End-to-end checks against a real Mac in the Simulator: `-pair <implink://…>` pairs at launch.
        if let i = CommandLine.arguments.firstIndex(of: "-pair"), CommandLine.arguments.indices.contains(i + 1),
           let pairing = LinkPairing(string: CommandLine.arguments[i + 1]) {
            let c = LinkClient()
            c.pair(pairing)
            _client = State(initialValue: c)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
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

    #if DEBUG
    @MainActor private static func demoClient() -> LinkClient {
        let c = LinkClient()
        c.loadDemo()
        return c
    }
    #endif
}

/// Pairing when there's no Mac yet; the stage once there is.
struct RootView: View {
    let client: LinkClient
    @State private var chat: ChatRoute?
    @State private var confirmUnpair = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            DungeonBackdrop()
            if client.pairing == nil {
                PairingView(client: client)
                    .transition(.opacity)
            } else {
                PhoneStage(client: client) { chat = ChatRoute(id: $0) }
                    .transition(.opacity)
                VStack {
                    StatusPill(client: client, confirmUnpair: $confirmUnpair)
                    Spacer()
                }
                .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: client.pairing == nil)
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
        .sheet(item: $chat) { route in
            ChatSheet(client: client, impID: route.id)
                .presentationDetents([.medium, .large])
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
            if CommandLine.arguments.contains("-openChat"), let first = client.imps.first {
                try? await Task.sleep(for: .seconds(1.5))
                chat = ChatRoute(id: first.id)
            }
            // `-ask <text>`: once connected, asks the first Imp and opens its chat (end-to-end checks).
            if let i = CommandLine.arguments.firstIndex(of: "-ask"), CommandLine.arguments.indices.contains(i + 1) {
                for _ in 0..<120 where !(client.isConnected && !client.imps.isEmpty) { try? await Task.sleep(for: .milliseconds(250)) }
                guard let first = client.imps.first else { return }
                client.ask(first.id, CommandLine.arguments[i + 1])
                chat = ChatRoute(id: first.id)
            }
        }
        #endif
    }
}

struct ChatRoute: Identifiable { var id: UUID }

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
