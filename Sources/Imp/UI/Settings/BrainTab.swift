import AppKit
import ImpKit
import SwiftUI

/// Three questions, one card each: where does the brain live, what's the key, which model.
/// An Imp that never picked a service uses the one new Imps use (the star in Brain services), and
/// one that names no model uses its service's: set once per service, not once per Imp.
struct BrainTab: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var keyCheck: (ok: Bool, text: String)?
    @State private var hello: (ok: Bool, text: String)?
    @State private var adding = false
    /// The model field sets the service's model rather than this Imp's own: it follows the service,
    /// and the service had none yet when the page opened (decided then, so typing doesn't flip it).
    @State private var editsService = false
    @Environment(\.impTint) private var tint

    private var brain: Brain { imp.brain ?? Brain() }
    private var service: Service? { model.prefs.ai.service(in: brain) }
    private var name: String { imp.name.isEmpty ? "this Imp" : imp.name }
    private var ownModel: String { brain.model.trimmingCharacters(in: .whitespaces) }

    /// What the model field shows and sets: the service's model or this Imp's own (see `editsService`).
    private func modelBinding(_ p: Service) -> Binding<String> {
        Binding(get: { editsService ? p.model : brain.model }, set: { new in
            if editsService {
                model.prefs.ai.setModel(new, for: p.id)
            } else {
                var b = brain
                b.model = new
                imp.brain = b
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            Card("Service", icon: "server.rack",
                 info: "Where \(name)'s brain lives: any OpenAI-compatible AI service, in the cloud (needs a key) or running on this Mac. The star marks the one new Imps use. Right-click a service you added to remove it.") {
                EvenGrid(minWidth: 150, spacing: 8) {
                    ForEach(model.prefs.ai.services) { choice in
                        ServiceTile(name: choice.label, local: choice.isLocal, picked: service?.id == choice.id,
                                    isDefault: model.prefs.ai.defaultService == choice.id,
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
                         info: "Like a password that lets \(name) think. It stays on this Mac and is shared with every Imp that uses \(p.label) (\(p.baseURL)).") {
                        checkButton(p)
                    } content: {
                        KeyField(model: model, service: p)
                    }
                }

                Card("Model", icon: "cpu", info: modelInfo(p)) {
                    modelAccessory(p)
                } content: {
                    HStack(spacing: 8) {
                        ModelField(model: modelBinding(p), placeholder: p.model.isEmpty ? "Model name" : p.model) {
                            try await model.assistant.client(for: p).models()
                        }
                        TestButton(title: "Say hi", action: {
                            let client = try model.assistant.client(brain: brain)
                            let name = model.prefs.ai.model(in: brain)
                            guard !name.isEmpty else { throw APIError.noModel }
                            return try await client.chat(model: name, messages: [
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
                .onAppear { decideEditing(p) }
                .onChange(of: p.id) { decideEditing(p) }
            }

            MemoryCard(model: model, imp: $imp)
        }
    }

    // MARK: Pieces

    private func decideEditing(_ p: Service) {
        editsService = ownModel.isEmpty && p.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func modelInfo(_ p: Service) -> String {
        let pick = "Different models are smarter, faster or cheaper. Pick one from the list, or type its name. Say hi checks that it answers."
        if editsService { return "\(pick) It's saved for \(p.label): every Imp on it thinks with it, unless one picks its own." }
        return "\(pick) Empty: \(name) uses \(p.label)'s model, set in All Imps › Brain services."
    }

    /// Whose model this is: \(p.label)'s (shared), or this Imp's own, with a way back.
    @ViewBuilder
    private func modelAccessory(_ p: Service) -> some View {
        if !editsService && !ownModel.isEmpty && ownModel != p.model {
            HStack(spacing: 2) {
                StatusText(text: "Only \(name)", symbol: "person.fill")
                    .help("\(name) thinks with its own model. The other Imps on \(p.label) use \(p.model.isEmpty ? "theirs" : p.model).")
                HoverIconButton(systemName: "arrow.up.circle", help: "Use \(ownModel) for every Imp on \(p.label)") {
                    model.prefs.ai.setModel(ownModel, for: p.id)
                    clearOwnModel()
                }
                if !p.model.isEmpty {
                    HoverIconButton(systemName: "arrow.uturn.backward", help: "Go back to \(p.label)'s model, \(p.model)") {
                        clearOwnModel()
                    }
                }
            }
        } else if editsService {
            StatusText(text: "For every Imp on \(p.label)", symbol: "person.3.fill")
                .help("Saved for \(p.label): every Imp on it thinks with it, unless one picks its own.")
        } else if !p.model.isEmpty {
            StatusText(text: "Same as \(p.label)", symbol: "person.3.fill")
                .help("\(name) uses \(p.label)'s model. Type another to give only \(name) its own.")
        }
    }

    private func clearOwnModel() {
        var b = brain
        b.model = ""
        imp.brain = b
        editsService = false
    }

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
        withAnimation(.snappy(duration: 0.2)) { model.removeService(p.id) }
        keyCheck = nil
        hello = nil
    }

    /// Moves this Imp to another service, with that service's model (a model name only means
    /// something on the service it came from).
    private func pick(_ choice: Service) {
        imp.brain = Brain(service: choice.id)
        keyCheck = nil
        hello = nil
    }
}

/// One place a brain can live.
private struct ServiceTile: View {
    let name: String
    let local: Bool
    let picked: Bool
    /// The service new Imps think with (a small star).
    var isDefault = false
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
                if isDefault {
                    Image(systemName: "star.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(picked ? Color.white.opacity(0.85) : tint)
                        .help("New Imps think with \(name). Change it with the star in All Imps › Brain services.")
                }
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
