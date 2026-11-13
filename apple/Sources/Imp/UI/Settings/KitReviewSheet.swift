import AppKit
import ImpDesign
import ImpKit
import SwiftUI
import UniformTypeIdentifiers

struct KitReviewSheet: View {
    let model: AppModel
    let flow: KitFlow
    @Bindable var review: KitReview
    @Bindable var router: HomeRouter
    @Environment(\.impTint) private var inherited
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kit: Kit { review.kit }
    /// The first Imp's colour: the sheet takes it on while the Imp arrives.
    private var tint: Color { kit.imps.first.map { Color.imp($0.hue) } ?? inherited }

    var body: some View {
        SheetFrame {
            HStack {
                Spacer()
                HoverIconButton(systemName: "xmark", help: "common.close") { router.kitFlow = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Spacing.page)
            .padding(.top, Spacing.page)
        } content: {
            KitHero(kit: kit, origin: review.origin)
            if !kit.permissions.isEmpty { permissionsCard }
            if !review.cautions.isEmpty { caution }
            if !kit.imps.isEmpty { impsSection }
            if !kit.triggers.isEmpty { triggersSection }
            if !kit.looseServers.isEmpty { serversSection }
            if !kit.animations.isEmpty { animationsSection }
            if !kit.problems.isEmpty { problemsCard }
        } footer: {
            if review.needsTarget {
                Text("For").font(Typeface.body).foregroundStyle(Tone.muted)
                CompactMenu(verbatim: targetName, symbol: review.target == nil ? "person.3.fill" : "person.fill") {
                    ForEach(model.prefs.imps) { imp in
                        Button { review.target = imp.id } label: {
                            if review.target == imp.id { Label(name(of: imp), systemImage: "checkmark") } else { Text(name(of: imp)) }
                        }
                    }
                    Section {
                        Button { review.target = nil } label: {
                            if review.target == nil { Label("Every Imp", systemImage: "checkmark") } else { Text("Every Imp") }
                        }
                    }
                }
                InfoTip("Who gets the triggers, tools and animations that aren't an Imp's own.")
            }
            Spacer()
            Button { add() } label: { Label(addTitle, systemImage: "plus") }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
                .disabled(review.count == 0)
                .help("Nothing is added until you press this.")
        }
        .environment(\.impTint, tint)
    }

    private var addTitle: LocalizedStringKey {
        let onlyImps = review.triggers.isEmpty && review.servers.isEmpty && review.animations.isEmpty
        return onlyImps && !review.imps.isEmpty ? "Add \(review.imps.count) Imps" : "Add \(review.count) items"
    }

    private func name(of imp: ImpProfile) -> String { imp.name.isEmpty ? String(localized: "Unnamed Imp") : imp.name }
    private var targetName: String { review.target.flatMap(model.profile).map(name(of:)) ?? String(localized: "Every Imp") }

    /// Everything the kit would be able to do, as plain lines, before the details below.
    private var permissionsCard: some View {
        let permissions = kit.permissions
        return VStack(alignment: .leading, spacing: Spacing.snug) {
            SectionHeader(info: "This is read from the kit itself, not from what its author says about it.", minHeight: nil) {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "checklist").foregroundStyle(permissions.hasCautions ? Tone.warnText : Tone.muted)
                    Text("What this can do").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                }
            }
            ForEach(permissions.lines) { line in
                Label {
                    Text(verbatim: line.text).font(Typeface.body).foregroundStyle(Tone.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.symbol(line.kind)).foregroundStyle(line.isCaution ? Tone.warnText : Tone.muted)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.card))
    }

    private static func symbol(_ kind: KitPermissions.Line.Kind) -> String {
        switch kind {
        case .computer: "cursorarrow.click.2"
        case .command, .shell: "terminal.fill"
        case .remote: "network"
        case .trigger: "bolt.fill"
        case .tools: "wrench.and.screwdriver.fill"
        }
    }

    /// Code that would run on this Mac, said plainly.
    private var caution: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            SectionHeader(info: "Only add it if you trust whoever sent it.", minHeight: nil) {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warnText)
                    Text("Runs commands on this Mac").font(Typeface.cardTitle).foregroundStyle(Tone.text)
                }
            }
            ForEach(review.cautions) { warning in
                Text(warning.text).font(Typeface.mono).foregroundStyle(Tone.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Tone.warnBackground))
    }

    /// A warning as a badge: what it is in a few words, the details in its tooltip.
    @ViewBuilder private func badge(_ warning: KitWarning) -> some View {
        switch warning.kind {
        case .runsCommand: Badge("Runs commands", symbol: "terminal.fill", color: Tone.warnText).help(warning.text)
        case .computerControl: Badge("Controls your Mac", symbol: "cursorarrow.click.2", color: Tone.warnText).help(warning.text)
        case .needsSecrets: Badge("Needs keys", symbol: "key.fill", color: Tone.warnText).help(warning.text)
        case .keysInUse: Badge("Keys in use", symbol: "keyboard", color: Tone.warnText).help(warning.text)
        case .brainMissing: Badge("Model not set up", symbol: "brain", color: Tone.warnText).help(warning.text)
        }
    }

    // MARK: Imps

    private var impsSection: some View {
        KitSection(icon: "person.fill", title: "Imps",
                   info: "It arrives at home. Its personality and triggers steer its tools, Mac commands included.") {
            ForEach(kit.imps) { imp in
                SelectableCard(isOn: review.binding(imp: imp.id), tint: Color.imp(imp.hue)) { impCard(imp) }
            }
            if review.hasChats {
                Row("Bring their chats along", icon: "bubble.left.and.bubble.right", info: "kit.help.chats") {
                    Toggle("Bring their chats along", isOn: $review.includeChats).labelsHidden().toggleStyle(.impSwitchBare)
                }
            }
        }
    }

    private func impCard(_ imp: KitImp) -> some View {
        let warnings = review.warnings(for: imp.id) + imp.triggers.flatMap { review.warnings(for: $0.id) }
        let tools = imp.toolsOn.map(\.title) + (imp.usesShell ? [String(localized: "Commands")] : [])
        let servers = imp.servers.compactMap { id in kit.servers.first { $0.id == id }?.name }
        let model = imp.brain.map(\.summary).flatMap { $0.isEmpty ? nil : $0 }
        return HStack(alignment: .top, spacing: Spacing.medium) {
            ImpPortrait(face: impFace(hue: imp.hue), shadow: false)
                .frame(width: Sizing.impPortrait, height: Sizing.impPortrait)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text(imp.name).font(Typeface.cardTitle).lineLimit(1)
                if !imp.personality.isEmpty {
                    Text(imp.personality).font(Typeface.body).foregroundStyle(Tone.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: Spacing.snug, lineSpacing: Spacing.snug) {
                    ForEach(warnings) { badge($0) }
                    Badge(verbatim: model ?? String(localized: "Your default model"), symbol: "brain")
                        .help("The model it thinks with.")
                    if tools.isEmpty {
                        Badge("No tools", symbol: "wrench.and.screwdriver.fill")
                    } else {
                        Badge("\(tools.count) tools", symbol: "wrench.and.screwdriver.fill").help(tools.joined(separator: ", "))
                    }
                    if !servers.isEmpty {
                        Badge(verbatim: servers.joined(separator: ", "), symbol: "puzzlepiece.extension.fill").help("The tools it uses.")
                    }
                    if !imp.triggers.isEmpty { Badge("\(imp.triggers.count) triggers", symbol: "bolt.fill") }
                    if !imp.chats.isEmpty { Badge("\(imp.chats.count) chats", symbol: "bubble.left.and.bubble.right.fill") }
                    if !imp.animations.isEmpty {
                        Badge("\(imp.animations.count) animations", symbol: "wand.and.stars")
                            .help(imp.animations.map(\.title).joined(separator: ", "))
                    }
                    if !imp.traits.isPlain { Badge(verbatim: imp.traits.summary, symbol: "theatermasks.fill").help("Its character, in everything it does.") }
                }
            }
        }
    }

    // MARK: Triggers and tools

    private var triggersSection: some View {
        KitSection(icon: "bolt.fill", title: "Triggers",
                   info: "A trigger can run tools and Mac commands. Read it first.") {
            ForEach(kit.triggers) { trigger in
                SelectableCard(isOn: review.binding(trigger: trigger.id)) { triggerCard(trigger) }
            }
        }
    }

    private func triggerCard(_ trigger: Shortcut) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(trigger.displayName).font(Typeface.cardTitle).lineLimit(1)
            Label(trigger.triggerSummary, systemImage: trigger.trigger.kind.symbol)
                .font(Typeface.caption).foregroundStyle(Tone.text).lineLimit(2)
            if trigger.command != .ask {
                Text(trigger.command.title).font(Typeface.body).foregroundStyle(Tone.muted)
            } else if !trigger.prompt.isEmpty {
                Text(trigger.prompt).font(Typeface.body).foregroundStyle(Tone.muted)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            let warnings = review.warnings(for: trigger.id)
            if (trigger.command == .ask && trigger.usesClipboard) || !warnings.isEmpty {
                FlowLayout(spacing: Spacing.snug, lineSpacing: Spacing.snug) {
                    ForEach(warnings) { badge($0) }
                    if trigger.command == .ask && trigger.usesClipboard {
                        Badge("Sends your clipboard", symbol: "doc.on.clipboard").help("It sends what you copied along with the instruction.")
                    }
                }
            }
        }
    }

    private var serversSection: some View {
        KitSection(icon: "puzzlepiece.extension.fill", title: "Tools", info: "kit.help.tools") {
            ForEach(kit.looseServers) { server in
                SelectableCard(isOn: review.binding(server: server.id)) { serverCard(server) }
            }
        }
    }

    private func serverCard(_ server: MCPServerConfig) -> some View {
        let local = server.transport == .stdio
        let warnings = review.warnings(for: server.id)
        return VStack(alignment: .leading, spacing: Spacing.snug) {
            Label { Text(server.name).lineLimit(1) } icon: { Image(systemName: local ? "terminal.fill" : "globe") }
                .font(Typeface.cardTitle)
            Text(local ? server.commandLine : server.url)
                .font(Typeface.mono).foregroundStyle(Tone.muted)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !warnings.isEmpty {
                FlowLayout(spacing: Spacing.snug, lineSpacing: Spacing.snug) { ForEach(warnings) { badge($0) } }
            }
        }
    }

    private var animationsSection: some View {
        KitSection(icon: "wand.and.stars", title: "Animations",
                   info: "Moves replace built-in animations. They run nothing on your Mac.") {
            ForEach(kit.animations) { animation in
                SelectableCard(isOn: review.binding(animation: animation.id)) { animationCard(animation) }
            }
        }
    }

    private func animationCard(_ a: MadeAnimation) -> some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            IconTile(systemName: a.symbol, side: Sizing.glyph)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text(a.title).font(Typeface.cardTitle).lineLimit(1)
                if !a.about.isEmpty {
                    Text(a.about).font(Typeface.body).foregroundStyle(Tone.text).lineLimit(2)
                }
                FlowLayout(spacing: Spacing.snug, lineSpacing: Spacing.snug) {
                    Badge(verbatim: String(format: "%.1f s", a.duration), symbol: "timer")
                    Badge("\(a.beats.count) beats", symbol: "metronome.fill")
                    if let r = a.replaces { Badge("Instead of \(r.title)", symbol: "arrow.triangle.swap") }
                    ForEach(AnimationTrigger.allCases.filter(a.triggers.contains)) { t in Badge(verbatim: t.title, symbol: t.symbol) }
                }
            }
        }
    }

    private var problemsCard: some View {
        Card("Skipped", icon: "exclamationmark.circle", info: "kit.help.skipped") {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(Array(kit.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem).font(Typeface.small).foregroundStyle(Tone.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Adding

    private func add() {
        if let decide = flow.adoption {
            flow.adoption = nil
            router.kitFlow = nil
            decide(true)
            return
        }
        var prefs = model.prefs
        let added = prefs.add(kit, imps: review.imps, triggers: review.triggers, servers: review.servers,
                              animations: review.animations, for: review.target,
                              withChats: review.includeChats)
        // Chats go to the Imp's folder before it appears, so it opens them as its own.
        if model.persists {
            for imported in added.imps where !imported.chats.isEmpty {
                var history = ChatHistory(folder: ChatHistory.folder(for: imported.id))
                for chat in imported.chats { history.adopt(chat) }
            }
        }
        withImpAnimation(ImpDesign.Motion.expand, reduceMotion: reduceMotion) { model.prefs = prefs }
        router.kitFlow = nil
        flow.onAdded?()
        // New Imps hatch on the stage first. Then, if a tool needs keys, its form opens.
        let needing = added.needingSecrets.first
        let target = review.target ?? flow.imp ?? added.imps.first?.id
        router.hatch(added.imps.map(\.id)) { [model, router] in
            guard let needing else { return }
            let imp = target ?? router.selection ?? model.prefs.imps[0].id
            HomeWindow.shared.show(model, settingsFor: imp, panel: .tools)
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                router.serverToEdit = needing
            }
        }
    }
}
