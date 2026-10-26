import AppKit
import ImpKit
import SwiftUI

/// One service: name, URL, key and a connection test, in two lines.
struct ServiceRow: View {
    let model: AppModel
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
                HoverIconButton(systemName: "trash", help: "Remove this service", tint: .red, action: remove)
            }
            HStack(spacing: 8) {
                Color.clear.frame(width: 20, height: 1)
                KeyField(model: model, service: service)
                TestButton(title: "Test", action: {
                    let count = try await model.assistant.client(for: service).models().count
                    return "Connected: \(count) models"
                }) { ok, text in withAnimation { result = (ok, text) } }.fixedSize()
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

/// A service's key: hidden by default, with show and paste. Shared by every Imp using the service.
struct KeyField: View {
    let model: AppModel
    let service: Service
    @State private var show = false

    private var key: Binding<String> {
        Binding(get: { model.assistant.key(for: service.id) }, set: { model.assistant.setKey($0, for: service.id) })
    }
    private var placeholder: String { service.isLocal ? "Not needed on this Mac" : "Paste the key here" }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if show { TextField(placeholder, text: key) } else { SecureField(placeholder, text: key) }
            }
            .impField(mono: show)
            .help("Kept in your login Keychain, never in plain files")
            HoverIconButton(systemName: show ? "eye.slash" : "eye", help: show ? "Hide key" : "Show key") { show.toggle() }
            HoverIconButton(systemName: "doc.on.clipboard", help: "Paste the key from the clipboard", action: paste)
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { key.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines) }
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
    @State private var check: (ok: Bool, text: String)?
    @State private var checking = false

    private var draft: Service { Service(name: name.trimmingCharacters(in: .whitespaces), baseURL: baseURL.trimmingCharacters(in: .whitespaces)) }
    private var isValid: Bool {
        guard let url = URL(string: draft.baseURL), url.host != nil, let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    var body: some View {
        SheetScaffold(icon: "server.rack", title: "Add a service",
                      info: "Any OpenAI-compatible API: in the cloud, or a server on this Mac. The key is kept in your Mac's Keychain.") {
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

/// Searchable list of the service's models (`GET /models`).
struct ModelBrowser: View {
    let model: AppModel
    let service: Service
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
            do { all = try await model.assistant.client(for: service).models() }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
    }
}
