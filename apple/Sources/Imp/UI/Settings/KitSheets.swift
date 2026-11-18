import AppKit
import ImpDesign
import ImpKit
import SwiftUI
import UniformTypeIdentifiers

/// The kit sheet: the box to paste into, until there's a kit to review.
struct KitFlowSheet: View {
    let model: AppModel
    @Bindable var flow: KitFlow
    @Bindable var router: HomeRouter

    var body: some View {
        Group {
            if let review = flow.review {
                KitReviewSheet(model: model, flow: flow, review: review, router: router)
            } else {
                KitEntrySheet(model: model, flow: flow, router: router)
            }
        }
        .task { await flow.autoload(model) }
    }
}

/// Paste JSON or a web address, or hand over a .json file.
struct KitEntrySheet: View {
    private static let dropHeight = Sizing.hit * 4
    private static let editorHeight = Sizing.hit * 3

    let model: AppModel
    @Bindable var flow: KitFlow
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var tint
    @State private var dropping = false
    @State private var notice: ImpNotice?

    private var isEmpty: Bool { flow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SheetScaffold(icon: "shippingbox.fill", title: "Add a kit or an Imp",
                      info: "Paste a kit, a web address or an imp:// link, or drop a file. You review it first.") {
            HStack(spacing: Spacing.small) {
                Button { paste() } label: { FitLabel("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.imp(.secondary, small: true))
                    .help("Fill in from the clipboard.")
            }
        } content: {
            if flow.isLoading {
                loading
            } else {
                dropZone
                SectionHeader("Or paste a kit or a web address", info: "kit.help.paste",
                              font: Typeface.caption, color: Tone.muted, minHeight: nil)
                .padding(.bottom, -Spacing.snug)
                EditorWell(text: $flow.text, codePlaceholder: "{ \"imps\": […] }   or   https://example.com/kit.json",
                           mono: true, height: Self.editorHeight)
            }
        } footer: {
            Button("Review") { Task { await flow.read(model: model) } }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(flow.isLoading || isEmpty)
        }
        .onChange(of: flow.error) { _, error in if let error { notice = .warning(error) } }
        .impNotice($notice)
    }

    private var loading: some View {
        VStack(spacing: Spacing.cozy) {
            ProgressView().controlSize(.regular)
            Text("Opening the kit…").font(Typeface.caption).foregroundStyle(Tone.text)
        }
        .frame(maxWidth: .infinity, minHeight: Self.dropHeight + Self.editorHeight)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
        .accessibilityElement(children: .combine)
    }

    private var dropZone: some View {
        VStack(spacing: Spacing.small) {
            Image(systemName: dropping ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(Typeface.title).foregroundStyle(dropping ? tint : Tone.muted)
                .symbolEffect(.bounce, value: dropping)
            Text("Drop a .json file here").font(Typeface.label).foregroundStyle(Tone.text)
            Button("Choose file…") { choose() }.buttonStyle(.imp(.secondary, small: true))
        }
        .frame(maxWidth: .infinity, minHeight: Self.dropHeight)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(dropping ? tint.opacity(Opacity.tintFill) : Tone.card))
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.first(where: \.isFileURL) else { return false }
            Task { await flow.read(file: file, model: model) }
            return true
        } isTargeted: { dropping = $0 }
        .impAnimation(ImpDesign.Motion.quick, value: dropping)
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        flow.text = text
        flow.error = nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a kit (.json)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await flow.read(file: url, model: model) }
    }
}

/// What's arriving: the Imps' faces in their own colours, the kit's name, what it says about itself, and what's in it.
struct KitHero: View {
    private static let faceSize = Sizing.heroFace
    private static let overlap = Spacing.page
    private static let maxFaces = 4

    let kit: Kit
    let origin: String

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            faces
            Text(kit.name.isEmpty ? String(localized: "Add a kit") : kit.name)
                .font(Typeface.title).foregroundStyle(Tone.text)
                .lineLimit(2).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !kit.about.isEmpty {
                Text(kit.about).font(Typeface.body).foregroundStyle(Tone.muted)
                    .lineLimit(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.snug) {
                if !kit.imps.isEmpty { Badge("\(kit.imps.count) Imps", symbol: "person.fill", color: Tone.text) }
                if !kit.triggers.isEmpty { Badge("\(kit.triggers.count) triggers", symbol: "bolt.fill", color: Tone.text) }
                if !kit.servers.isEmpty { Badge("\(kit.servers.count) tools", symbol: "puzzlepiece.extension.fill", color: Tone.text) }
                if !kit.animations.isEmpty { Badge("\(kit.animations.count) animations", symbol: "wand.and.stars", color: Tone.text) }
            }
            StatusText(text: "From \(origin)", symbol: "tray.and.arrow.down")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.tight)
    }

    @ViewBuilder private var faces: some View {
        let shown = Array(kit.imps.prefix(Self.maxFaces))
        let more = kit.imps.count - shown.count
        HStack(spacing: -Self.overlap) {
            if shown.isEmpty {
                IconTile(systemName: "shippingbox.fill", filled: true, side: Self.faceSize)
            }
            ForEach(shown) { imp in
                ImpPortrait(face: impFace(hue: imp.hue, mood: .happy), shadow: false)
                    .frame(width: Self.faceSize, height: Self.faceSize)
            }
            if more > 0 {
                Text(verbatim: "+\(more)").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                    .frame(width: Self.faceSize * 0.6, height: Self.faceSize * 0.6)
                    .background(Circle().fill(Tone.card))
                    .padding(.leading, Self.overlap + Spacing.tight)
            }
        }
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// A group's title above its cards: an icon, a name, a count, and an ⓘ for what to watch out for.
struct KitSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let info: LocalizedStringKey
    @ViewBuilder var content: Content
    @Environment(\.impTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            SectionHeader(info: info, minHeight: nil) {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: icon).font(.icon(.medium, weight: .semibold)).foregroundStyle(LegibleTint())
                    Text(title).font(Typeface.cardTitle).foregroundStyle(Tone.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}
