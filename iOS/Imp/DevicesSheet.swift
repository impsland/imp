import ImpDesign
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
                    ShakeSettingsCard()
                    ServerCard(hub: hub)
                    requests
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .dismissesKeyboard()
            .keyboardGap()
            .background(Dungeon.deep)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // The navigation bar keeps the system's button: system chrome sizes and tints it.
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.buttonStyle(.automatic) }
            }
        }
        .impControls(tint: Dungeon.ember)
        .tipHost()
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
        VStack(spacing: Spacing.medium) {
            Text("This iPhone is called")
                .font(Typeface.caption).foregroundStyle(Dungeon.muted)
            NameField(hub: hub)
            Text("Scan this with Imp on another device")
                .font(Typeface.caption).foregroundStyle(Dungeon.muted)
                .padding(.top, Spacing.tight)
            InviteCode(hub: hub)
            // Every button of the card is as wide as the card's content.
            VStack(spacing: Spacing.small) {
                if let problem { IssueBadge(text: problem, opensAtOnce: true) }
                if CodeScanner.isAvailable {
                    Button { problem = nil; scanning = true } label: { Label("Scan a Code", systemImage: "qrcode.viewfinder") }
                        .buttonStyle(EmberButtonStyle())
                }
                Button { problem = LinkClipboard.join(hub) } label: { Label("Paste Link", systemImage: "doc.on.clipboard") }
                    .buttonStyle(EmberButtonStyle(filled: false))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .impCard()
        .animation(.easeInOut, value: problem)
    }

    // MARK: Requests

    /// How long an Imp of this iPhone waits for its service and what it does when the network drops.
    /// Changes count from the next request.
    private var requests: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dungeon.ember)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Dungeon.ember.opacity(0.16)))
                    .accessibilityHidden(true)
                Text("Requests").font(Typeface.cardTitle).foregroundStyle(Dungeon.cream).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                IssueBadge(text: String(localized: "How long an Imp waits for a model, and what it does when the network drops for a moment."), kind: .info)
                Spacer(minLength: 0)
            }
            limitRow("Wait up to", info: String(localized: "A request that hasn't finished after this long ends with a message instead of waiting on."),
                     value: limit(\.timeoutSeconds), range: RequestLimits.timeoutControlRange, step: RequestLimits.timeoutStep) { "\(Int($0)) s" }
            CardDivider()
            limitRow("Retries", info: String(localized: "How many times a request is tried again after the network drops or the service is busy. Wrong keys and bad requests are never retried."),
                     value: limit(\.retries, as: Double.self), range: Double(RequestLimits.retriesRange.lowerBound)...Double(RequestLimits.retriesRange.upperBound), step: 1) { "\(Int($0))" }
            CardDivider()
            limitRow("First wait", info: String(localized: "The pause before the first retry."),
                     value: limit(\.retryDelaySeconds), range: RequestLimits.delayRange, step: RequestLimits.delayStep) { "\($0.formatted()) s" }
            CardDivider()
            limitRow("Longer each time", info: String(localized: "Each pause is this many times longer than the one before."),
                     value: limit(\.backoff), range: RequestLimits.backoffRange, step: RequestLimits.backoffStep) { "× \($0.formatted())" }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .impCard()
    }

    private func limitRow(_ title: LocalizedStringKey, info: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                          text: @escaping (Double) -> String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(Typeface.body).foregroundStyle(Dungeon.cream).lineLimit(2)
            IssueBadge(text: info, kind: .info)
            Spacer(minLength: 8)
            ImpStepper(value: value, in: range, step: step) {
                Text(verbatim: text(value.wrappedValue)).frame(minWidth: 44, alignment: .trailing)
            }
            .accessibilityLabel(title)
        }
        .frame(minHeight: Sizing.hit)
    }

    /// One of the limits as a number to step.
    private func limit(_ path: WritableKeyPath<RequestLimits, Double>) -> Binding<Double> {
        Binding(get: { pocket.limits[keyPath: path] },
                set: { var l = pocket.limits; l[keyPath: path] = $0; pocket.setLimits(l) })
    }

    private func limit(_ path: WritableKeyPath<RequestLimits, Int>, as: Double.Type) -> Binding<Double> {
        Binding(get: { Double(pocket.limits[keyPath: path]) },
                set: { var l = pocket.limits; l[keyPath: path] = Int($0); pocket.setLimits(l) })
    }

    // MARK: Linked devices

    private var linked: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hub.links.isEmpty {
                Text("Nobody is linked yet. Show your code to another device, or scan theirs, and Imps can travel between you.")
                    .font(Typeface.body).foregroundStyle(Dungeon.muted)
                    .padding(.horizontal, 4)
            } else {
                Text("Linked")
                    .font(Typeface.caption).foregroundStyle(Dungeon.muted)
                    .padding(.horizontal, 4)
                ForEach(hub.links) { link in device(link.device) }
                if !elsewhere.isEmpty {
                    Text("Away")
                        .font(Typeface.caption).foregroundStyle(Dungeon.muted)
                        .padding(.horizontal, 4).padding(.top, 6)
                    VStack(spacing: 0) {
                        ForEach(elsewhere, id: \.id) { imp in held(imp, by: hub.holders[imp.id].map(hub.deviceName)) }
                    }
                    .padding(14).impCard()
                }
                Button { forgettingEveryone = true } label: { Label("Forget Everyone…", systemImage: "xmark.circle") }
                    .buttonStyle(.destructive)
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
                    .background(Dungeon.ember.opacity(0.16), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(.body, design: .rounded, weight: .semibold)).foregroundStyle(Dungeon.cream)
                    status(of: device)
                }
                Spacer(minLength: 8)
                Button("Forget…") { forgetting = device }
                    .buttonStyle(.destructive)
            }
            Toggle(isOn: Binding(get: { hub.isTrusted(device.id) }, set: { hub.setTrusted(device.id, $0) })) {
                Text("Mine").font(Typeface.label).foregroundStyle(Dungeon.cream)
            }
            .toggleStyle(.impSwitch)
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
        .impCard()
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
                .buttonStyle(.secondary)
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
                .impField(mono: true)
                .focused($focused)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
            Text("With a server, your devices find each other from anywhere, not just on your Wi-Fi. The server only passes encrypted data along. It can't read anything.")
                .font(.system(.footnote, design: .rounded)).foregroundStyle(Dungeon.muted)
        }
        .padding(14)
        .impCard()
        .onAppear { text = hub.server }
    }

    private func commit() {
        invalid = !hub.setServer(text)
    }
}
