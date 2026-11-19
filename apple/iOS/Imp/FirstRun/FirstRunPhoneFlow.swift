import ImpDesign
import ImpKit
import SwiftUI

/// A Brain on one screen, with no steps: the kind of service, then its address, the key and the model together.
/// The model is a choice that looks like the fields around it: blank is "Picked for you" (the first model that
/// chats, chosen when it wakes), and a tap opens `ModelPicker`, the service's models with a search. The same form
/// wakes the first Imp and sets any Imp's Brain. Its one button is `PhoneBrainButton`, pinned by the screen that
/// shows it. A Brain that works taps once in the hand, one that fails taps the error.
struct PhoneBrainForm: View {
    @Bindable var flow: FirstRunModel
    @FocusState private var focus: Field?
    @State private var picking = false

    private enum Field: Hashable { case address, key, model }

    /// Picks Remote or Local and goes to the field it needs first: the key for Remote, the address for Local.
    /// Focus moves before the choice: Local disables the key, and a disabled field that has the keyboard gives it
    /// up, so the keyboard would drop and come back. Moved first, it goes from one field to the other and stays.
    private func pick(_ preset: ServicePreset) {
        focus = preset.isLocal ? .address : .key
        flow.choose(preset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            // Remote and Local as one compact, neutral choice (as on the Mac): the selected segment takes the text
            // colour, not the Imp's; the tint is for the main action.
            ImpSegmented("firstrun.service.kind",
                         selection: Binding(get: { flow.choice }, set: { if let preset = $0 { pick(preset) } }),
                         options: flow.presets.map { Optional($0) }, title: { $0?.title ?? "" }, symbol: { $0?.symbol ?? "" },
                         fills: true)
                .environment(\.impTint, Tone.text)
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Titled(title: "firstrun.service.address") {
                    TextField("firstrun.service.address", text: $flow.address, prompt: Text(verbatim: "https://…/v1"))
                        .impField(mono: true)
                        .codeEntry(.address)
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = flow.showsKey ? .key : nil }
                        .accessibilityIdentifier("brain.address")
                }
                Titled(title: "firstrun.service.key") {
                    // On the address's keyboard, so going from one to the other changes nothing (see `SecretField`).
                    SecretField(title: flow.showsKey ? "firstrun.service.key" : "firstrun.service.key_local", text: $flow.key)
                        .impField(mono: true)
                        .focused($focus, equals: .key)
                        // Local needs no key: the field stays, disabled, so nothing below it moves.
                        .disabled(!flow.showsKey)
                        .submitLabel(.done)
                        .onSubmit { focus = nil }
                        .accessibilityIdentifier("brain.key")
                }
                Titled(title: "firstrun.step.model") { model }
            }
            // One quiet line that says what is needed, and a problem in its place: both are laid out, so the
            // slot is as tall as the taller one and nothing moves when a problem comes or goes.
            ZStack(alignment: .topLeading) {
                Text(flow.needsHost && !flow.showsKey ? "firstrun.service.host_note" : "firstrun.service.note")
                    .font(Typeface.caption).foregroundStyle(Tone.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(flow.problemText == nil ? 1 : 0)
                    .accessibilityHidden(flow.problemText != nil)
                StatusText(verbatim: flow.problemText ?? " ", symbol: "exclamationmark.circle", color: Tone.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(flow.problemText == nil ? 0 : 1)
                    .accessibilityHidden(flow.problemText == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(flow.path.isBusy)
        // Felt as well as seen: the Brain works, or it didn't.
        .onChange(of: flow.path.step) { _, step in
            if step == .awake { Haptics.notify(.success) }
            if step == .failed { Haptics.notify(.error) }
        }
    }

    /// The model: a choice that looks like the fields above, with its name, or "Picked for you" when blank. When the
    /// service gives no list (or it cannot be read), the name is typed straight into the field instead.
    @ViewBuilder private var model: some View {
        if flow.models.isEmpty, flow.problemText != nil, flow.path.step != .loadingModels {
            typedModel
        } else {
            pickedModel
        }
    }

    private var typedModel: some View {
        TextField(text: $flow.model, prompt: Text("phone.brain.model_auto").foregroundStyle(Tone.muted)) {
            Text("firstrun.step.model")
        }
        .font(Typeface.mono)
        .foregroundStyle(Tone.text)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .focused($focus, equals: .model)
        .submitLabel(.done)
        .onSubmit { focus = nil }
        .padding(.horizontal, Spacing.cozy)
        .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
        .accessibilityIdentifier("brain.model")
    }

    private var pickedModel: some View {
        Button {
            focus = nil
            picking = true
        } label: {
            HStack(spacing: Spacing.small) {
                if flow.model.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label { Text("phone.brain.model_auto") } icon: { Image(systemName: "sparkles") }
                        .font(Typeface.body).foregroundStyle(Tone.muted)
                } else {
                    Text(verbatim: flow.model).font(Typeface.mono).foregroundStyle(Tone.text)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Spacing.small)
                Image(systemName: "chevron.up.chevron.down").font(.icon(.small, weight: .semibold)).foregroundStyle(Tone.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.cozy)
            .frame(maxWidth: .infinity, minHeight: Sizing.control)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Tone.well))
            .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("firstrun.step.model"))
        .accessibilityValue(flow.model.isEmpty ? Text("phone.brain.model_auto") : Text(verbatim: flow.model))
        .accessibilityHint(Text("phone.brain.list_models"))
        .accessibilityIdentifier("brain.model")
        .sheet(isPresented: $picking) { ModelPicker(flow: flow).phoneAppearance() }
    }
}

/// The service's models to choose one, with a search: "Picked for you" first, then a name typed in the search
/// that the service doesn't list ("Use …"), then the models, the chosen one ticked and first. The list loads
/// when it opens. A pick closes it.
struct ModelPicker: View {
    @Bindable var flow: FirstRunModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    private var shown: [String] { flow.models(matching: query) }

    var body: some View {
        VStack(spacing: Spacing.small) {
            SheetBar(close: { dismiss() }) {
                Text("firstrun.step.model").font(Typeface.cardTitle).foregroundStyle(Tone.text).accessibilityAddTraits(.isHeader)
            }
            .sheetBarInsets()
            FieldWell(symbol: "magnifyingglass", mono: true) {
                TextField("firstrun.model.search", text: $query, prompt: Text("firstrun.model.search"))
                    .codeEntry()
                    .submitLabel(.search)
                    .accessibilityIdentifier("models.search")
            } actions: {
                if !query.isEmpty { FieldAction(systemName: "xmark.circle.fill", help: "common.clear") { query = "" } }
            }
            .padding(.horizontal, Spacing.page)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if typed.isEmpty {
                        row(Text("phone.brain.model_auto"), detail: Text("phone.brain.model_auto_detail"), symbol: "sparkles",
                            picked: flow.model.trimmingCharacters(in: .whitespaces).isEmpty) { choose("") }
                    } else if !flow.models.contains(typed) {
                        row(Text(words("phone.brain.model_use", typed)), detail: nil, symbol: "keyboard", picked: false) { choose(typed) }
                    }
                    ForEach(shown, id: \.self) { name in
                        row(Text(verbatim: name).font(Typeface.mono), detail: nil, symbol: nil, picked: name == flow.model) { choose(name) }
                    }
                    status
                }
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Tone.card))
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.small).padding(.bottom, Spacing.wide)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .impControls()
        .background(Tone.surface)
        .presentationBackground(Tone.surface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { flow.listModels() }
    }

    /// While the list loads, or why it can't, with Try again.
    @ViewBuilder private var status: some View {
        if flow.path.step == .loadingModels {
            HStack(spacing: Spacing.small) {
                ProgressView()
                Text("firstrun.service.loading").font(Typeface.caption).foregroundStyle(Tone.muted)
            }
            .frame(maxWidth: .infinity, minHeight: Sizing.hit)
            .padding(.vertical, Spacing.small)
        } else if flow.models.isEmpty, let problem = flow.problemText {
            VStack(spacing: Spacing.small) {
                StatusText(verbatim: problem, symbol: "exclamationmark.circle", color: Tone.warnText)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Button("common.try_again") { flow.listModels() }.buttonStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.medium)
        }
    }

    private func row(_ title: Text, detail: Text?, symbol: String?, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.small) {
                if let symbol {
                    Image(systemName: symbol).font(.icon(.medium)).foregroundStyle(LegibleTint()).frame(width: Sizing.mark)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 0) {
                    title.font(Typeface.body).foregroundStyle(Tone.text).lineLimit(1).truncationMode(.middle)
                    if let detail { detail.font(Typeface.caption).foregroundStyle(Tone.muted) }
                }
                Spacer(minLength: Spacing.small)
                if picked {
                    Image(systemName: "checkmark").font(.icon(.small, weight: .bold)).foregroundStyle(LegibleTint())
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, minHeight: Sizing.hit, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func choose(_ name: String) {
        flow.model = name
        Haptics.selection()
        dismiss()
    }
}

/// The form's one button. It lists the models when it has to, checks the Brain with a tiny request and keeps it.
/// "Wake {name} up" for an Imp that sleeps, "Check and save" for one that thinks.
struct PhoneBrainButton: View {
    @Bindable var flow: FirstRunModel
    var hasBrain = false

    var body: some View {
        Group {
            switch flow.path.step {
            case .awake:
                // A beat to see it worked, before the sheet goes.
                Button {} label: { Label { Text(verbatim: words("firstrun.check.ok", flow.impName)) } icon: { Image(systemName: "checkmark.circle.fill") } }
                    .allowsHitTesting(false)
            case .loadingModels, .checking:
                Button {} label: { Label { Text(verbatim: words("firstrun.check.running", flow.impName)) } icon: { ProgressView() } }
                    .disabled(true)
            case .done:
                EmptyView()
            case .failed:
                Button("common.try_again") { flow.wakeUp() }
            case .service, .model:
                if hasBrain {
                    Button("phone.brain.check_save") { flow.wakeUp() }
                } else {
                    Button { flow.wakeUp() } label: { Text(verbatim: words("firstrun.wake", flow.impName)) }
                }
            }
        }
        .buttonStyle(WideButtonStyle())
        .accessibilityIdentifier("brain.go")
    }
}
