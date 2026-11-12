import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// One service: name, URL, key, the model its Imps think with, and whether new Imps use it.
struct ServiceRow: View {
    @Bindable var model: AppModel
    @Binding var service: Service
    let remove: () -> Void
    @State private var result: (ok: Bool, text: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How many Imps think with this service.
    private var usedBy: Int { model.prefs.imps.filter { model.prefs.ai.service(in: $0.brain)?.id == service.id }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.cozy) {
                IconTile(systemName: service.isLocal ? "desktopcomputer" : "cloud.fill")
                Text(verbatim: service.label).font(Typeface.cardTitle).foregroundStyle(Tone.text).lineLimit(1)
                InfoTip(service.isLocal ? "settings.service.local.info" : "settings.service.cloud.info")
                Spacer(minLength: Spacing.small)
                DefaultServiceButton(name: service.label, isDefault: model.prefs.ai.defaultService == service.id) {
                    withImpAnimation(ImpDesign.Motion.quick, reduceMotion: reduceMotion) { model.prefs.ai.defaultService = service.id }
                }
                HoverIconButton(systemName: "trash", help: "Remove this service", tint: Tone.danger, action: remove)
            }
            FieldRow("common.name", info: "settings.service.name.info") {
                TextField("common.name", text: $service.name).impField()
            }
            FieldRow("Address", info: "settings.service.address.info") {
                TextField(String("https://…/v1"), text: $service.baseURL).impField(mono: true).autocorrectionDisabled()
            }
            FieldRow("Key", info: "settings.service.key.info") {
                KeyField(model: model, service: service)
            }
            FieldRow("Model", info: "settings.service.model.info") {
                ModelField(model: $service.model, placeholder: "Model for every Imp on \(service.label)") {
                    try await model.assistant.client(for: service).models()
                }
            }
            HStack(spacing: Spacing.small) {
                Text(verbatim: String.localizedStringWithFormat(NSLocalizedString("brains.used_by", comment: ""), usedBy))
                    .font(Typeface.small).foregroundStyle(Tone.muted).lineLimit(1)
                Spacer(minLength: Spacing.small)
                if let result {
                    StatusText(verbatim: result.text, symbol: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                               color: result.ok ? Tone.good : Tone.danger)
                        .help(result.text)
                        .transition(.opacity)
                }
                TestButton(title: "Test", action: {
                    let count = try await model.assistant.client(for: service).models().count
                    return String(localized: "Works. \(count) models")
                }) { ok, text in withImpAnimation(ImpDesign.Motion.fade, reduceMotion: reduceMotion) { result = (ok, text) } }
            }
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .impCard()
    }
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
                        tint: isDefault ? tint : Tone.muted) {
            if !isDefault { pick() }
        }
        .accessibilityAddTraits(isDefault ? .isSelected : [])
    }
}

/// A model name: type it, or choose it from the service's list (`load`) with the action inside the field.
struct ModelField: View {
    @Binding var model: String
    var placeholder: LocalizedStringKey = "brain.model_placeholder"
    let load: @MainActor () async throws -> [String]
    @State private var browsing = false

    var body: some View {
        FieldWell(mono: true) {
            TextField(placeholder, text: $model).autocorrectionDisabled()
        } actions: {
            FieldAction(systemName: "list.bullet", help: "brain.choose_model") { browsing = true }
                .impPopover(isPresented: $browsing, arrowEdge: .bottom) {
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
    @State private var problem: String?

    private var saved: Bool { model.assistant.hasKey(service.id) }
    private var key: Binding<String> {
        Binding(get: { draft }, set: {
            draft = $0
            if !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problem = model.assistant.setKey($0, for: service.id) ? nil : String(localized: "firstrun.error.key_not_saved")
            }
        })
    }
    private var inKeychain: Bool { model.prefs.keysInKeychain }
    private var placeholder: LocalizedStringKey {
        if saved { return inKeychain ? "Saved in your Keychain" : "Saved on this Mac" }
        return service.isLocal ? "Not needed on this Mac" : "Paste the key here"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            FieldWell(mono: show) {
                Group {
                    if show { TextField(placeholder, text: key) } else { SecureField(placeholder, text: key) }
                }
                .help(inKeychain ? "Kept in your login Keychain" : "Kept in a private file only your account can read")
            } actions: {
                FieldAction(systemName: show ? "eye.slash" : "eye", help: show ? "Hide key" : "Show key") { show.toggle() }
                FieldAction(systemName: "doc.on.clipboard", help: "Paste key", action: paste)
                if saved {
                    FieldAction(systemName: "trash", help: "Remove key", action: remove)
                }
            }
            if let problem {
                StatusText(verbatim: problem, symbol: "xmark.octagon.fill", color: Tone.danger)
            }
        }
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { key.wrappedValue = s.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func remove() {
        draft = ""
        problem = nil
        model.assistant.setKey("", for: service.id)
    }
}

/// The service choice (Remote or Local) and the address, name and key of a service, as ONE component: the
/// "Add a service" sheet and the first run both show it. A choice fills the address (still freely editable,
/// so any OpenAI-compatible service works), each links to its key or model page, and Local is marked when
/// it answers on this computer. Nothing is focused by itself. `extra` adds fields under the key.
struct ServiceFields<Extra: View>: View {
    let choice: ServicePreset?
    let found: (ServicePreset) -> Bool
    let pick: (ServicePreset) -> Void
    @Binding var address: String
    @Binding var key: String
    let name: Binding<String>?
    let namePlaceholder: String
    let showsKey: Bool
    let submit: () -> Void
    let extra: Extra

    init(choice: ServicePreset?, found: @escaping (ServicePreset) -> Bool = { _ in false }, pick: @escaping (ServicePreset) -> Void,
         address: Binding<String>, key: Binding<String>, name: Binding<String>? = nil, namePlaceholder: String = "",
         showsKey: Bool = true, submit: @escaping () -> Void = {}, @ViewBuilder extra: () -> Extra) {
        self.choice = choice; self.found = found; self.pick = pick
        _address = address; _key = key; self.name = name; self.namePlaceholder = namePlaceholder
        self.showsKey = showsKey; self.submit = submit; self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ServicePresetGrid(choice: choice, found: found, pick: pick)
            FieldRow("firstrun.service.address", info: "settings.service.address.info") {
                TextField(String("https://…/v1"), text: $address).impField(mono: true).autocorrectionDisabled()
                    .onSubmit(submit)
            }
            if let name {
                FieldRow("common.name", info: "settings.service.name.info") {
                    TextField(namePlaceholder, text: name).impField().onSubmit(submit)
                }
            }
            if showsKey {
                FieldRow("firstrun.service.key", info: "firstrun.service.note") {
                    SecureField("Paste the key here", text: $key).impField().onSubmit(submit)
                }
            }
            extra
        }
        .noInitialFocus()
    }
}

extension ServiceFields where Extra == EmptyView {
    init(choice: ServicePreset?, found: @escaping (ServicePreset) -> Bool = { _ in false }, pick: @escaping (ServicePreset) -> Void,
         address: Binding<String>, key: Binding<String>, name: Binding<String>? = nil, namePlaceholder: String = "",
         showsKey: Bool = true, submit: @escaping () -> Void = {}) {
        self.init(choice: choice, found: found, pick: pick, address: address, key: key, name: name, namePlaceholder: namePlaceholder,
                  showsKey: showsKey, submit: submit) { EmptyView() }
    }
}

/// Remote and Local as two tiles, side by side when they fit.
struct ServicePresetGrid: View {
    let choice: ServicePreset?
    let found: (ServicePreset) -> Bool
    let pick: (ServicePreset) -> Void

    var body: some View {
        EvenGrid(minWidth: Sizing.menuTitle, spacing: Spacing.snug) {
            ForEach(ServicePreset.all) { preset in
                PresetTile(symbol: preset.symbol, title: preset.title, detail: "", picked: choice == preset,
                           found: found(preset), foundHelp: String(localized: "firstrun.service.found"),
                           link: preset.link, linkHelp: preset.link.absoluteString) { pick(preset) }
                    .help(preset.baseURL)
            }
        }
    }
}

/// "Add a service": Remote or Local (the shared fields: the choice, address, name and key) and a model, with
/// a connection test. Remote is picked to begin with, with its address and name filled in.
struct AddServiceSheet: View {
    let model: AppModel
    let added: (Service) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choice = ServicePreset.standard
    @State private var name = ""
    @State private var baseURL = ServicePreset.standard?.baseURL ?? ""
    @State private var key = ""
    @State private var modelName = ""
    @State private var check: (ok: Bool, text: String)?
    @State private var checking = false

    private var draft: Service {
        Service(name: name.trimmingCharacters(in: .whitespaces), baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                model: modelName.trimmingCharacters(in: .whitespaces))
    }
    private var isValid: Bool { ServicePreset.isValidAddress(baseURL) }

    var body: some View {
        SheetScaffold(icon: "server.rack", title: "brain.add_service",
                      info: "Any OpenAI-compatible API. The key stays on this Mac.") {
            ServiceFields(choice: choice, pick: pick, address: $baseURL, key: $key, name: $name,
                          namePlaceholder: draft.label == String(localized: "Unnamed service") ? String(localized: "My service") : draft.label,
                          showsKey: choice?.isLocal != true) {
                FieldRow("brain.model") {
                    ModelField(model: $modelName, placeholder: "For every Imp on it") { [draft, key] in
                        try await OpenAIClient(baseURL: draft.baseURL, apiKey: key).models()
                    }
                    .disabled(!isValid)
                }
            }
            .padding(Spacing.roomy)
            .impCard(radius: Radius.medium)
        } footer: {
            Button("Test") { Task { await test() } }
                .buttonStyle(.imp(.secondary)).disabled(!isValid || checking)
            if checking { ProgressView().controlSize(.small) }
            if let check {
                StatusText(verbatim: check.text, symbol: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill",
                           color: check.ok ? Tone.good : Tone.danger)
                    .help(check.text)
            }
            Spacer()
            Button("common.add") {
                var p = draft
                p.name = p.label
                guard model.assistant.setKey(key, for: p.id) else {
                    check = (false, String(localized: "firstrun.error.key_not_saved"))
                    return
                }
                model.prefs.ai.add(p)
                added(p)
                dismiss()
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(!isValid)
        }
    }

    /// A choice fills the address and, when the name is untouched, the name.
    private func pick(_ picked: ServicePreset) {
        choice = picked
        check = nil
        baseURL = picked.baseURL
    }

    private func test() async {
        checking = true
        defer { checking = false }
        do {
            let count = try await OpenAIClient(baseURL: draft.baseURL, apiKey: key).models().count
            check = (true, String(localized: "Works. \(count) models"))
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
        VStack(alignment: .leading, spacing: Spacing.small) {
            PopoverHeader("brain.model") {
                if !loading, error == nil { Text("\(filtered.count) models") }
            }
            TextField("Search models…", text: $query).impField()
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).font(Typeface.small).foregroundStyle(Tone.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered, id: \.self) { id in
                        Button { pick(id) } label: {
                            HStack {
                                Text(verbatim: id).font(Typeface.mono).foregroundStyle(Tone.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .impListRow()
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                }
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.bottom, Spacing.medium)
        .padding(.top, Spacing.tight)
        .frame(width: Sizing.popoverWidth, height: Sizing.popoverWidth)
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
