import AppKit
import ImpDesign
import ImpKit
import SwiftUI

/// What the Imp thinks with. The same Brain as the other Imps, or its own: a service from one generic
/// list (a hosted service would be one more entry) and a model. With no Brain the Imp sleeps, and
/// that is a calm state: the lantern is unlit, nothing is red.
struct BrainPanel: View {
    @Bindable var model: AppModel
    @Binding var imp: ImpProfile
    @State private var check: ActionState = .idle
    @Environment(\.postNotice) private var postNotice
    @State private var adding = false
    /// The setup is shown in place while the Imp has no service at all, and stays until its last step is over
    /// (the Brain works once the second step's check is done).
    @State private var settingUp: Bool

    init(model: AppModel, imp: Binding<ImpProfile>) {
        self.model = model
        _imp = imp
        _settingUp = State(initialValue: !model.isReady(imp.wrappedValue.id) && model.prefs.ai.services.isEmpty)
    }

    private var ai: AIConfig { model.prefs.ai }
    private var service: Service? { ai.service(in: imp.brain) }
    private var usesOwn: Bool { imp.brain != nil }
    private var ready: Bool { model.isReady(imp.id) }

    var body: some View {
        if settingUp {
            BrainSetup(model: model, id: imp.id) { settingUp = false }
        } else {
            normal
        }
    }

    @ViewBuilder private var normal: some View {
        PanelSection("brain.title", icon: "lightbulb.fill") {
            status
            Row("brain.source", icon: "person.2.fill", info: "brain.help.source") {
                ImpSegmented("brain.source", selection: Binding(get: { usesOwn }, set: chooseOwn), options: [false, true],
                             title: { own in own ? String(localized: "brain.use_own") : String(localized: "brain.use_app") },
                             symbol: { own in own ? "person.fill" : "person.2.fill" })
            }
            .settingAnchor(.brainSource)
        }
        if usesOwn {
            PanelList("brain.service", icon: "cloud.fill", info: "brain.help.service") { services }
        }
        MemoryCard(model: model, imp: $imp)
    }

    // MARK: Status

    /// The lantern, what the Imp thinks with (or that it sleeps) with the one
    /// button at the trailing edge: Check when there is a Brain, Wake when there is none.
    private var status: some View {
        HStack(spacing: Spacing.medium) {
            IconTile(systemName: ready ? "lightbulb.fill" : "lightbulb")
                .opacity(ready ? 1 : Opacity.dimmed)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.snug) {
                    if ready, let service {
                        Text(verbatim: "\(service.label), \(ai.model(in: imp.brain))")
                            .font(Typeface.body).foregroundStyle(Tone.text)
                    } else {
                        Text("brain.none").font(Typeface.body).foregroundStyle(Tone.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if ready {
                Button { runCheck() } label: { StatefulLabel("common.check", symbol: "checkmark.seal", state: check) }
                    .buttonStyle(.imp(.secondary, small: true))
                    .disabled(check == .working)
                    .impActionState($check)
            } else {
                Button(action: chooseOrAdd) {
                    FitLabel(usesOwn ? "brain.add_service" : "brain.choose", systemImage: usesOwn ? "plus" : "lightbulb.fill")
                }
                .buttonStyle(.imp(.primary, small: true))
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Services

    /// One generic list. Each entry is a service the app knows: a local model, a key service, or one the user added.
    private var services: some View {
        VStack(spacing: Spacing.snug) {
            ForEach(ai.services) { choice in
                ServiceChoiceRow(service: choice, picked: service?.id == choice.id) { pick(choice) }
                    .contextMenu {
                        Button(role: .destructive) { remove(choice) } label: { Label("common.remove", systemImage: "trash") }
                    }
                    .accessibilityAction(named: Text("common.remove")) { remove(choice) }
            }
            AddServiceButton { adding = true }
        }
        .sheet(isPresented: $adding) { AddServiceSheet(model: model) { pick($0) } }
    }

    // MARK: Check

    private func runCheck() {
        check = .working
        let brain = imp.brain
        let name = imp.callName
        let service = ai.service(in: brain)
        let modelName = ai.model(in: brain)
        let prompt = imp.systemPrompt
        Task {
            do {
                let client = try model.assistant.client(brain: brain)
                guard !modelName.isEmpty else { throw APIError.noModel }
                _ = try await client.chat(model: modelName, messages: [.system(prompt), .user("Say hi to me in one short sentence.")]).text
                check = .done
                postNotice(.success(words("brain.check_ok", name)))
            } catch {
                check = .failed
                postNotice(.error(BrainCheck.message(for: error, service: service, model: modelName, imp: name)))
            }
        }
    }

    // MARK: Changes

    private func chooseOwn(_ own: Bool) {
        check = .idle
        imp.brain = own ? Brain(service: ai.service(in: nil)?.id) : nil
    }

    /// Services exist but this Imp has none: show the list to choose from, or add one when it already chose.
    private func chooseOrAdd() {
        if usesOwn { adding = true } else { chooseOwn(true) }
    }

    private func pick(_ choice: Service) {
        imp.brain = Brain(service: choice.id)
        check = .idle
    }

    /// Removes a service from the app (every Imp shares it): any Imp using it moves to the first one left.
    private func remove(_ p: Service) {
        model.removeService(p.id)
        check = .idle
    }
}

/// The first run, in place in the Brain panel of an Imp with no service: the same page as the first-run
/// sheet. The panel's own header has Back.
private struct BrainSetup: View {
    let model: AppModel
    let id: UUID
    let finished: () -> Void
    @State private var flow: FirstRunModel

    init(model: AppModel, id: UUID, finished: @escaping () -> Void) {
        self.model = model
        self.id = id
        self.finished = finished
        _flow = State(initialValue: FirstRunHost.model(app: model, id: id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.roomy) {
            FirstRunFlow(flow: flow)
            FirstRunPrimaryButton(flow: flow)
        }
        .onChange(of: flow.path.step) { _, step in if step == .done { finished() } }
    }
}

/// What a failed Brain check says.
enum BrainCheck {
    /// A plain sentence for what went wrong: it names the service and says what to do next.
    static func message(for error: Error, service: Service?, model: String, imp: String) -> String {
        let name = service?.label ?? ""
        guard let api = error as? APIError else {
            return service?.isLocal == true ? words("error.brain.local") : words("error.brain.unreachable", name)
        }
        switch api {
        case .missingKey, .keyDenied: return words("error.brain.key", name)
        case .http(let status, _) where status == 401 || status == 403: return words("error.brain.key", name)
        case .http(let status, _) where status == 404: return words("error.brain.model", name, model)
        case .timedOut: return words("error.brain.timeout", name)
        case .noService, .needsBrain, .noModel: return words("error.brain.none", imp)
        case .badURL: return words("error.brain.unreachable", name)
        case .http, .emptyResponse: return words("error.generic")
        }
    }
}

/// One service in the list: its name, where it runs. The Imp's own is filled with the Imp's colour.
private struct ServiceChoiceRow: View {
    let service: Service
    let picked: Bool
    let action: () -> Void
    @Environment(\.impTint) private var tint
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: service.isLocal ? "desktopcomputer" : "cloud.fill").font(.icon(.large))
                    .frame(width: Sizing.mark).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    (service.label.isEmpty ? Text("brain.unnamed") : Text(verbatim: service.label)).font(Typeface.body)
                    Text(service.isLocal ? "On this Mac" : "In the cloud").font(Typeface.small)
                        .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.muted))
                }
                Spacer(minLength: Spacing.small)
                if picked { Image(systemName: "checkmark").font(.icon(.medium)).accessibilityHidden(true) }
            }
            .foregroundStyle(picked ? AnyShapeStyle(OnTint(tint)) : AnyShapeStyle(Tone.text))
            .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
            .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(picked ? AnyShapeStyle(TintFill(tint)) : AnyShapeStyle(hover ? Tone.cardHover : Tone.card)))
            .focusRing(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous), shown: focused)
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// The last pebble of the list: add a service.
private struct AddServiceButton: View {
    let action: () -> Void
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label("brain.add_service", systemImage: "plus")
                .font(Typeface.body).foregroundStyle(Tone.text)
                .padding(.horizontal, Spacing.medium).padding(.vertical, Spacing.small)
                .frame(maxWidth: .infinity, minHeight: Sizing.control, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).fill(hover ? Tone.cardHover : Tone.card))
                .focusRing(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous), shown: focused)
                .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .impAnimation(ImpDesign.Motion.hover, value: hover)
        .help("brain.help.add_service")
    }
}
