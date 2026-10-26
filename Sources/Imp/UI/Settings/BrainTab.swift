import AppKit
import ImpKit
import SwiftUI

/// Three questions, one card each: where does the brain live, what's the key, which model.
struct BrainTab: View {
    let model: AppModel
    @Binding var imp: ImpProfile
    @State private var keyCheck: (ok: Bool, text: String)?
    @State private var hello: (ok: Bool, text: String)?
    @State private var browsing = false
    @State private var adding = false
    @Environment(\.impTint) private var tint

    private var brain: Binding<Brain> {
        Binding(get: { imp.brain ?? model.prefs.ai.brain }, set: { imp.brain = $0 })
    }
    private var service: Service? { model.prefs.ai.service(in: brain.wrappedValue) }
    private var name: String { imp.name.isEmpty ? "this Imp" : imp.name }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Service", icon: "server.rack",
                 info: "Where \(name)'s brain lives: any OpenAI-compatible AI service, in the cloud (needs a key) or running on this Mac. Right-click a service you added to remove it.") {
                EvenGrid(minWidth: 150, spacing: 8) {
                    ForEach(model.prefs.ai.services) { choice in
                        ServiceTile(name: choice.label, local: choice.isLocal, picked: service?.id == choice.id,
                                    remove: { remove(choice) }) {
                            pick(choice)
                        }
                    }
                    ServiceTile(name: "Add a service", local: false, picked: false, icon: "plus") { adding = true }
                }
            }
            .sheet(isPresented: $adding) { AddServiceSheet(model: model) { pick($0) } }

            if let p = service {
                if p.isLocal {
                    Card("No key needed", icon: "checkmark.shield.fill",
                         info: "\(p.label) runs on this Mac (\(p.baseURL)). Make sure it's open, then pick a model below.") {
                        checkButton(p)
                    } content: {
                        EmptyView()
                    }
                } else {
                    Card("\(p.label) key", icon: "key.fill",
                         info: "Like a password that lets \(name) think. It's kept in your Mac's Keychain and shared with every Imp that uses \(p.label) (\(p.baseURL)).") {
                        checkButton(p)
                    } content: {
                        KeyField(model: model, service: p)
                    }
                }

                Card("Model", icon: "cpu",
                     info: "Different models are smarter, faster or cheaper. Pick one from the list, or type its name. Say hi checks that it answers.") {
                    HStack(spacing: 8) {
                        TextField("Model name", text: brain.model).impField(mono: true)
                        Button { browsing = true } label: { Label("Choose", systemImage: "list.bullet") }
                            .buttonStyle(.imp(.secondary, small: true))
                            .popover(isPresented: $browsing, arrowEdge: .bottom) {
                                ModelBrowser(model: model, service: p) { brain.model.wrappedValue = $0; browsing = false }
                            }
                        TestButton(title: "Say hi", action: {
                            let client = try model.assistant.client(brain: brain.wrappedValue)
                            return try await client.chat(model: brain.wrappedValue.model, messages: [
                                .system(imp.systemPrompt), .user("Say hi to me in one short sentence."),
                            ]).text
                        }) { ok, text in withAnimation { hello = (ok, text) } }
                        .fixedSize()
                    }
                    if let hello {
                        Text(hello.ok ? "“\(hello.text)”" : hello.text)
                            .font(.callout).italic(hello.ok)
                            .foregroundStyle(hello.ok ? Color.primary : Color.red)
                            .lineLimit(4).textSelection(.enabled)
                            .transition(.opacity)
                    }
                }
            }

            MemoryCard(model: model, imp: $imp)
        }
    }

    // MARK: Pieces

    private func checkButton(_ p: Service) -> some View {
        HStack(spacing: 8) {
            if let keyCheck {
                StatusText(text: keyCheck.text, color: keyCheck.ok ? .green : .red).help(keyCheck.text)
            }
            TestButton(title: "Check", action: {
                let count = try await model.assistant.client(for: p).models().count
                return "Works: \(count) models"
            }) { ok, text in withAnimation { keyCheck = (ok, text) } }
            .fixedSize()
        }
    }

    /// Removes a service from the app (it's shared by every Imp): any Imp using it, this one
    /// included, moves to the first service left, like removing it in the app's settings.
    private func remove(_ p: Service) {
        withAnimation(.snappy(duration: 0.2)) { model.prefs.removeService(p.id) }
        keyCheck = nil
        hello = nil
    }

    private func pick(_ choice: Service) {
        brain.wrappedValue.service = choice.id
        keyCheck = nil
        hello = nil
    }
}

/// One place a brain can live.
private struct ServiceTile: View {
    let name: String
    let local: Bool
    let picked: Bool
    var icon: String?
    /// Services the user added can be removed (right-click, or the × on hover).
    var remove: (() -> Void)?
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon ?? (local ? "desktopcomputer" : "cloud.fill"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(picked ? .white : tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? "Unnamed" : name).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    if icon == nil {
                        Text(local ? "On this Mac" : "In the cloud").font(.system(size: 10.5)).opacity(0.7).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .foregroundStyle(picked ? .white : .primary)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(picked ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.white.opacity(hover ? 0.09 : 0.05))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked ? Color.white.opacity(0.2) : Dungeon.cardEdge))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let remove, hover {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Remove \(name.isEmpty ? "this service" : name) from every Imp")
                .accessibilityLabel("Remove \(name)")
                .offset(x: 5, y: -5)
                .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            if let remove {
                Button(role: .destructive, action: remove) { Label("Remove “\(name)”", systemImage: "trash") }
            }
        }
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityAction(named: "Remove") { remove?() }
    }
}
