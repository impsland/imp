import ImpKit
import SwiftUI

/// Everything about linking, in one place: this iPhone's name and code, the devices it is linked
/// with and the Imps of this iPhone they hold, and the Imp server.
struct DevicesSheet: View {
    let hub: LinkHub
    let pocket: PocketRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: LinkDevice?
    @State private var forgettingEveryone = false
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    thisIPhone
                    linked
                    ServerCard(hub: hub)
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Dungeon.deep)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .fullScreenCover(isPresented: $scanning) { LinkScanner(hub: hub, problem: $problem, scanning: $scanning) }
        .confirmationDialog(forgetting.map { String(localized: "Forget \($0.name)?") } ?? "",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { device in
            Button("Forget \(device.name)", role: .destructive) { hub.forget(device.id) }
        } message: { device in
            Text("Imps of this iPhone that \(device.name) holds come home. Its Imps visiting here go home to it. To link again, one of you shows a new code.")
        }
        .confirmationDialog("Forget every device?", isPresented: $forgettingEveryone, titleVisibility: .visible) {
            Button("Forget Everyone", role: .destructive) { hub.forgetEveryone() }
        } message: {
            Text("Imps of this iPhone on other devices come home, and every Imp visiting here goes home. Codes shown before stop working; link again with a new one.")
        }
    }

    // MARK: This iPhone

    private var thisIPhone: some View {
        VStack(spacing: 14) {
            Text("This iPhone is called")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            NameField(hub: hub)
            Text("Scan this with Imp on another device")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
                .padding(.top, 4)
            InviteCode(hub: hub)
            HStack(spacing: 6) {
                if let problem { IssueBadge(text: problem, opensAtOnce: true) }
                if CodeScanner.isAvailable {
                    Button { problem = nil; scanning = true } label: { Label("Scan a Code", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(EmberButtonStyle())
                }
            }
            Button { problem = LinkClipboard.join(hub) } label: { Label("Paste Link", systemImage: "doc.on.clipboard") }
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(Dungeon.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .card()
        .animation(.easeInOut, value: problem)
    }

    // MARK: Linked devices

    private var linked: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hub.links.isEmpty {
                Text("Nobody is linked yet. Show your code to another device, or scan theirs, and Imps can travel between you.")
                    .font(.system(.callout, design: .rounded)).foregroundStyle(Dungeon.muted)
                    .padding(.horizontal, 4)
            } else {
                Text("Linked")
                    .font(.system(.footnote, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.muted)
                    .padding(.horizontal, 4)
                ForEach(hub.links) { link in device(link.device) }
                if !elsewhere.isEmpty {
                    Text("Away")
                        .font(.system(.footnote, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.muted)
                        .padding(.horizontal, 4).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(elsewhere, id: \.id) { imp in held(imp, by: hub.holders[imp.id].map(hub.deviceName)) }
                    }
                    .padding(14).card()
                }
                Button(role: .destructive) { forgettingEveryone = true } label: { Label("Forget Everyone…", systemImage: "xmark.circle") }
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
    }

    /// Imps of this iPhone held by a device it isn't linked with (one it passed them on to).
    private var elsewhere: [LinkImp] {
        pocket.looks.filter { imp in
            hub.holders[imp.id].map { holder in !hub.links.contains { $0.id == holder } } ?? false
        }
    }

    private func device(_ device: LinkDevice) -> some View {
        let holding = pocket.looks.filter { hub.holders[$0.id] == device.id }
        let visiting = hub.visits.filter { $0.home.id == device.id }.map(\.imp.name)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: device.kind == .mac ? "macbook" : "iphone")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Dungeon.flame)
                    .frame(width: 40, height: 40)
                    .background(Dungeon.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.cream)
                    status(of: device)
                }
                Spacer(minLength: 8)
                Button("Forget…", role: .destructive) { forgetting = device }
                    .font(.system(.footnote, design: .rounded, weight: .medium))
            }
            Toggle(isOn: Binding(get: { hub.isTrusted(device.id) }, set: { hub.setTrusted(device.id, $0) })) {
                Text("Mine").font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Dungeon.cream)
            }
            .tint(Dungeon.ember)
            Text("Turn on only for your own devices: their requests may then use the tools of your Imps.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            if !holding.isEmpty {
                VStack(spacing: 0) {
                    ForEach(holding, id: \.id) { held($0, by: nil) }
                }
            }
            if !visiting.isEmpty {
                Label("Visiting here: \(visiting.formatted())", systemImage: "arrow.down.right.circle")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
            }
        }
        .padding(14)
        .card()
        .accessibilityElement(children: .contain)
    }

    private func status(of device: LinkDevice) -> some View {
        let connected = hub.isConnected(device.id)
        let text = !connected ? String(localized: "Away") : hub.viaHop.contains(device.id) ? String(localized: "Connected through the server") : String(localized: "Connected")
        return HStack(spacing: 6) {
            Circle().fill(connected ? Dungeon.good : Dungeon.muted).frame(width: 7, height: 7)
            Text(text).font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
        }
        .accessibilityElement(children: .combine)
    }

    /// An Imp of this iPhone that another device holds, with the way to call it home.
    private func held(_ imp: LinkImp, by holder: String?) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.imp(imp.hue)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text(imp.name).font(.system(.subheadline, design: .rounded, weight: .medium)).foregroundStyle(Dungeon.cream)
                if let holder {
                    Text("With \(holder)").font(.system(.caption, design: .rounded)).foregroundStyle(Dungeon.muted)
                }
            }
            Spacer(minLength: 8)
            Button { hub.callHome(imp.id) } label: { Label("Call Home", systemImage: "house") }
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .accessibilityLabel("Call \(imp.name) Home")
        }
        .padding(.vertical, 6)
    }
}

/// The Imp server this iPhone waits at, so other devices can reach it from anywhere.
private struct ServerCard: View {
    let hub: LinkHub
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Server").font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.cream)
                if invalid {
                    IssueBadge(text: String(localized: "That isn't a server address. Use a host name such as imp.example.org."))
                }
            }
            TextField(String("imp.example.org"), text: $text)
                .focused($focused)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Dungeon.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
            Text("With a server, your devices find each other from anywhere, not just on your Wi-Fi. The server only passes encrypted data along. It can't read anything.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
        }
        .padding(14)
        .card()
        .onAppear { text = hub.server }
    }

    private func commit() {
        invalid = !hub.setServer(text)
    }
}
