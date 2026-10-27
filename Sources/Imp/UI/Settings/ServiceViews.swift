import AppKit
import ImpKit
import SwiftUI

/// One service: name, URL, key, the model its Imps think with, and whether new Imps use it.
struct ServiceRow: View {
    @Bindable var model: AppModel
    @Binding var service: Service
    let remove: () -> Void
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: service.isLocal ? "desktopcomputer" : "cloud.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20)
                    .help(service.isLocal ? "On this Mac" : "In the cloud")
                TextField("Name", text: $service.name).impField().frame(width: 150)
                TextField("https://…/v1", text: $service.baseURL).impField(mono: true).autocorrectionDisabled()
                DefaultServiceButton(name: service.label, isDefault: model.prefs.ai.defaultService == service.id) {
                    withAnimation(.snappy(duration: 0.2)) { model.prefs.ai.defaultService = service.id }
                }
                HoverIconButton(systemName: "trash", help: "Remove this service", tint: .red, action: remove)
            }
            HStack(spacing: 8) {
                rowIcon("key.fill", help: "Its key")
                KeyField(model: model, service: service)
                TestButton(title: "Test", action: {
                    let count = try await model.assistant.client(for: service).models().count
                    return "Connected: \(count) models"
                }) { ok, text in withAnimation { result = (ok, text) } }.fixedSize()
            }
            HStack(spacing: 8) {
                rowIcon("cpu", help: "The model every Imp on \(service.label) thinks with, unless it picks its own")
                ModelField(model: $service.model, placeholder: "Model every Imp on \(service.label) uses") {
                    try await model.assistant.client(for: service).models()
                }
            }
            if let result {
                StatusText(text: result.text, symbol: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                           color: result.ok ? .green : .red)
                    .help(result.text)
                    .padding(.leading, 28)
                    .transition(.opacity)
            }
        }
    }
}

private func rowIcon(_ symbol: String, help: String) -> some View {
    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
        .frame(width: 20).help(help)
}

/// A star: filled on the service new Imps think with; click another to make it the one.
struct DefaultServiceButton: View {
    let name: String
    let isDefault: Bool
    let pick: () -> Void
    @Environment(\.impTint) private var tint

    var body: some View {
        HoverIconButton(systemName: isDefault ? "star.fill" : "star",
                        help: isDefault ? "New Imps think with \(name)" : "Make new Imps think with \(name)",
                        tint: isDefault ? tint : .secondary) {
            if !isDefault { pick() }
        }
        .accessibilityAddTraits(isDefault ? .isSelected : [])
    }
}

/// A model name: type it, or choose it from the service's list (`load`).
struct ModelField: View {
    @Binding var model: String
    var placeholder = "Model name"
    let load: @MainActor () async throws -> [String]
    @State private var browsing = false

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $model).impField(mono: true).autocorrectionDisabled()
            Button { browsing = true } label: { Label("Choose", systemImage: "list.bullet") }
                .buttonStyle(.imp(.secondary, small: true))
                .fixedSize()
                .help("Pick from the models the service offers")
                .popover(isPresented: $browsing, arrowEdge: .bottom) {
                    ModelBrowser(load: load) { model = $0; browsing = false }
                }
        }
    }
}

/// A service's key: hidden by default, with show, paste and remove. Shared by every Imp using the
/// service. A saved key is never read back to show it here (reading may ask for the user's
/// password): the field says it's saved, and whatever is typed or pasted replaces it.
struct KeyField: View {
    let model: AppModel
    let service: Service
    @State private var show = false
    @State private var draft = ""

    private var saved: Bool { model.assistant.hasKey(service.id) }
    private var key: Binding<String> {
        Binding(get: { draft }, set: {
            draft = $0
            if !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.assistant.setKey($0, for: service.id) }
        })
    }
    private var inKeychain: Bool { model.prefs.keysInKeychain }
    private var placeholder: String {
        if saved { return inKeychain ? "Saved in your Keychain" : "Saved on this Mac" }
        return service.isLocal ? "Not needed on this Mac" : "Paste the key here"
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if show { TextField(placeholder, text: key) } else { SecureField(placeholder, text: key) }
            }
            .impField(mono: show)
            .help(inKeychain ? "Kept in your login Keychain" : "Kept in a private file on this Mac that only your account can read")
            if !saved && model.assistant.hasKeychainKeyOnly(service.id) {
                IssueTip(text: "An earlier version of Imp kept this key in your Keychain. Paste it here again, or switch on “Keep keys in the Keychain” in Settings › Brain keys.",
                         symbol: "key.slash.fill")
            }
            HoverIconButton(systemName: show ? "eye.slash" : "eye", help: show ? "Hide key" : "Show key") { show.toggle() }
            HoverIconButton(systemName: "doc.on.clipboard", help: "Paste the key from the clipboard", action: paste)
            if saved {
                HoverIconButton(systemName: "trash", help: "Remove the key", action: remove)
            }
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { key.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func remove() {
        draft = ""
        model.assistant.setKey("", for: service.id)
    }
}

/// Well-known OpenAI-compatible addresses, offered only as shortcuts for typing the base URL.
/// Nothing in Imp depends on them.
enum ServiceHints {
    static let all: [(name: String, baseURL: String)] = [
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
        ("OpenAI", "https://api.openai.com/v1"),
    ]
}

/// "Add a service": any OpenAI-compatible endpoint. One-click addresses on top, then address,
/// name and key, with a connection check.
struct AddServiceSheet: View {
    let model: AppModel
    let added: (Service) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.impTint) private var tint
    @State private var name = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var modelName = ""
    @State private var check: (ok: Bool, text: String)?
    @State private var checking = false

    private var draft: Service {
        Service(name: name.trimmingCharacters(in: .whitespaces), baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                model: modelName.trimmingCharacters(in: .whitespaces))
    }
    private var isValid: Bool {
        guard let url = URL(string: draft.baseURL), url.host != nil, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        SheetScaffold(icon: "server.rack", title: "Add a service",
                      info: "Any OpenAI-compatible API: in the cloud, or a server on this Mac. The key stays on this Mac. Its model is the one every Imp on it thinks with, unless an Imp picks its own on its Brain tab.") {
            VStack(alignment: .leading, spacing: 10) {
                EvenGrid(minWidth: 96, spacing: 6) {
                    ForEach(ServiceHints.all, id: \.name) { hint in
                        ChoiceChip(title: hint.name, picked: draft.baseURL == hint.baseURL) {
                            let wasHint = name.isEmpty || ServiceHints.all.contains { $0.name == name }
                            baseURL = hint.baseURL
                            if wasHint { name = hint.name }
                            check = nil
                        }
                        .help(hint.baseURL)
                    }
                }
                FieldRow("Address") {
                    TextField("https://…/v1", text: $baseURL).impField(mono: true).autocorrectionDisabled()
                }
                FieldRow("Name") {
                    TextField(draft.label == "Unnamed service" ? "My service" : draft.label, text: $name).impField()
                }
                FieldRow("Key") {
                    SecureField(draft.isLocal ? "Not needed on this Mac" : "Paste the key here", text: $key).impField()
                }
                FieldRow("Model") {
                    ModelField(model: $modelName, placeholder: "Every Imp on it uses this") { [draft, key] in
                        try await OpenAIClient(baseURL: draft.baseURL, apiKey: key).models()
                    }
                    .disabled(!isValid)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).fill(Dungeon.card))
            .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).strokeBorder(Dungeon.cardEdge))
        } footer: {
            Button("Check") { Task { await test() } }
                .buttonStyle(.imp(.secondary)).disabled(!isValid || checking)
            if checking { ProgressView().controlSize(.small) }
            if let check {
                StatusText(text: check.text, symbol: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                           color: check.ok ? .green : .red)
                    .help(check.text)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.quiet).keyboardShortcut(.cancelAction)
            Button("Add") {
                var p = draft
                p.name = p.label
                model.prefs.ai.add(p)
                model.assistant.setKey(key, for: p.id)
                added(p)
                dismiss()
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!isValid)
        }
    }

    private func test() async {
        checking = true
        defer { checking = false }
        do {
            let count = try await OpenAIClient(baseURL: draft.baseURL, apiKey: key).models().count
            check = (true, "Works! \(count) models to choose from.")
        } catch {
            check = (false, error.localizedDescription)
        }
    }
}

/// Searchable list of a service's models (`GET /models`, through `load`).
struct ModelBrowser: View {
    let load: @MainActor () async throws -> [String]
    let pick: (String) -> Void
    @State private var all: [String] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search models…", text: $query).impField()
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.self) { id in
                        Button { pick(id) } label: {
                            HStack {
                                Text(id).font(.system(.body, design: .monospaced))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            Text("\(filtered.count) models").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 380, height: 360)
        .task {
            do { all = try await load() }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
    }
}
