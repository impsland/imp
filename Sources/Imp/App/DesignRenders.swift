import Carbon.HIToolbox
import AppKit
import ImpKit
import SwiftUI

/// Offline renders from the live character code: the app icon, and a contact sheet for review.
@MainActor
enum IconRenderer {
    /// `Imp --render-icon <dir>`: the .iconset used by scripts/build-app.sh.
    static func renderIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for (suffix, px) in [("", base), ("@2x", base * 2)] {
                let image = render(AppIcon().frame(width: CGFloat(px), height: CGFloat(px)), scale: 1)
                write(image, to: dir.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
            }
        }
    }

    /// `Imp --render-dmg-background <dir>`: background.png and background@2x.png for the
    /// installer disk image (scripts/dmg-settings.py places the icons on it).
    static func renderDMGBackground(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (suffix, scale) in [("", 1.0), ("@2x", 2.0)] {
            write(render(DMGBackground(), scale: scale), to: dir.appendingPathComponent("background\(suffix).png"))
        }
    }

    /// `Imp --render-moods <file.png> [cell]`: every mood plus head turns.
    static func renderMoods(to url: URL, cell: CGFloat) {
        var items: [(String, Face)] = Mood.allCases.map { ("\($0)", .settled($0)) }
        items += [("look ←", .settled(.idle, lookX: -0.8)), ("look ↗", .settled(.idle, lookX: 0.7, lookY: -0.6)),
                  ("look ↓", .settled(.idle, lookY: 0.9)), ("look ↙", .settled(.idle, lookX: -0.6, lookY: 0.8)),
                  ("look ↑", .settled(.idle, lookY: -0.9))]
        renderSheet(items, columns: 8, cell: cell, to: url)
    }

    /// `Imp --render-transition <from> <to> <file.png>`: a filmstrip of the springs moving Imp
    /// from one mood to another (every 50 ms), to review how expressions change.
    static func renderTransition(from: Mood, to: Mood, to url: URL) {
        let animator = FaceAnimator()
        var t = 0.0
        for _ in 0..<240 { t += 1 / 60; _ = animator.step(to: Face(from), at: t) }   // settle on the start
        var frames: [(String, Face)] = []
        for i in 0..<14 {
            frames.append(("\(i * 50) ms", animator.face))
            for _ in 0..<3 { t += 1 / 60; _ = animator.step(to: Face(to), at: t) }
        }
        renderSheet(frames, columns: 7, cell: 140, to: url)
    }

    /// `Imp --render-turns <file.png> [cell]`: every head turn, yaw × pitch, to check the horns.
    static func renderTurns(to url: URL, cell: CGFloat) {
        let steps = [-1.0, -0.5, 0, 0.5, 1]
        let items = steps.flatMap { y in steps.map { x in ("\(x), \(y)", Face.settled(.idle, lookX: x, lookY: y)) } }
        renderSheet(items, columns: steps.count, cell: cell, to: url)
    }

    private static func renderSheet(_ items: [(String, Face)], columns: Int, cell: CGFloat, to url: URL) {
        let sheet = Grid(horizontalSpacing: 0, verticalSpacing: 6) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)], id: \.0) { item in
                        VStack(spacing: 2) {
                            ImpPortrait(face: item.1).frame(width: cell, height: cell)
                            Text(item.0).font(.system(size: 13, design: .rounded))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.99, green: 0.98, blue: 0.96))
        write(render(sheet, scale: 2), to: url)
    }

    /// `Imp --render-status-icon <file.png>`: the menu bar template at 10×, plus 1× and 2× for legibility.
    static func renderStatusIcon(to url: URL) {
        let (w, h) = (200 + 20 + 40 + 40, 200)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        StatusIcon.image.draw(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        StatusIcon.image.draw(in: NSRect(x: 214, y: 90, width: 20, height: 20))
        StatusIcon.image.draw(in: NSRect(x: 246, y: 80, width: 40, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `Imp --render-home <screen> <file.png> [imps=N] [select=N] [out=N] [hidden=1] [width=W] [height=H]`: the real
    /// app window (live controls) rendered offscreen for design review. Screens: `home`, `egg`, an Imp tab
    /// (`looks`, `brain`, `tools`, `shortcuts`), `general-<tab>`, or the `add-service` / `add-tool` / `add-shortcut` / `edit-shortcut` sheets. `hidden=1`: the desktop Imps are hidden.
    static func renderHome(screen: String, to url: URL, width: CGFloat = 780, height: CGFloat = 600, sampleImps: Int = 1, select: Int = 0, out: Int? = nil, hidden: Bool = false) {
        let model = AppModel(persist: false)          // review renders never write the user's preferences
        model.prefs = ImpPreferences()
        for _ in 1..<max(1, sampleImps) { model.addImp() }
        let ids = model.prefs.imps.map(\.id)
        let chosen = ids[min(max(select, 0), ids.count - 1)]
        if sampleImps > 1, let i = model.prefs.imps.indices.dropFirst().first {
            // Something to look at: a shortcut and a borrowed tool.
            var a = Shortcut(name: "Translate", hotkey: Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: Hotkey.control | Hotkey.option),
                              prompt: ShortcutIdea.all[0].prompt)
            a.performer = model.prefs.imps[i].id
            model.prefs.shortcuts = [a]
            let files = MCPExamples.all[0]
            model.prefs.mcpServers = [files]
            model.prefs.imps[i].servers = [files.id]
            model.prefs.ai.add(Service(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "some/model"))
            model.prefs.ai.add(Service(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2"))
        }
        if let out, model.prefs.imps.indices.contains(out) { model.prefs.imps[out].isActive = true }
        if hidden { model.setHidden(true) }
        let router = HomeRouter()
        router.selection = chosen
        switch screen {
        case "home": router.screen = .home
        case "egg": router.screen = .home; router.selection = nil
        case let s where s.hasPrefix("general-"):
            router.screen = .general
            router.generalTab = GeneralTab(rawValue: String(s.dropFirst(8))) ?? .brains
        default:
            router.screen = .imp(chosen)
            router.impTab = ImpTab.allCases.first { $0.rawValue == screen || $0.title.lowercased() == screen } ?? .me
        }
        let root: AnyView = switch screen {
        case "add-service": AnyView(AddServiceSheet(model: model) { _ in }.background(Color(nsColor: .windowBackgroundColor)))
        case "add-tool": AnyView(ServerEditor(draft: MCPExamples.examples.first { !$0.isComplete }!.server,
                                                  isNew: true, hub: model.assistant.hub) { _ in }
            .background(Color(nsColor: .windowBackgroundColor)))
        case "add-shortcut", "edit-shortcut":
            AnyView(ShortcutSheet(model: model, imp: chosen, shortcut: model.prefs.shortcuts.first ?? Shortcut(name: "", prompt: "", performer: chosen),
                                  isNew: screen == "add-shortcut", save: { _ in }, duplicate: { _ in }, delete: {}, close: {})
                .background(Color(nsColor: .windowBackgroundColor)))
        default: AnyView(HomeView(model: model, router: router))
        }
        // Sheets get the render's height as their window (there's no app window to hang from).
        let host = NSHostingView(rootView: root.environment(\.sheetRoom, height))
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: width, height: height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))     // let SwiftUI lay out and draw
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    /// `Imp --render-bubble <file.png> [dark]`: every bubble state, with real controls, for design review.
    static func renderBubble(to url: URL, dark: Bool) {
        let model = AppModel(persist: false)
        let imp = ImpModel(id: model.prefs.imps[0].id, app: model)
        let layout = BubbleLayout()
        // A chat with a tool call, recapped, then carried on.
        var chat = ChatHistory(folder: nil)
        let date = Date(timeIntervalSinceReferenceDate: 812_000_000)
        chat.append(ChatTurn(date: date, request: "Plan a weekend in Lisbon", reply: "Alfama on Saturday, Belém on Sunday. Pastéis at 9."),
                    remembering: [.user("Plan a weekend in Lisbon"), .assistant("Alfama on Saturday, Belém on Sunday.")])
        chat.append(ChatTurn(date: date + 60, request: "Save it", reply: "Saved: [lisbon.md](lisbon.md)",
                             steps: [ChatTurn.Step(icon: "terminal", title: "echo … > lisbon.md", request: "echo … > lisbon.md", response: "", failed: false)]),
                    remembering: [.user("Save it"), .assistant("Saved")])
        chat.recap("- Weekend in **Lisbon**: Alfama Saturday, Belém Sunday.\n- The plan is saved in `lisbon.md`.", at: date + 120)
        chat.append(ChatTurn(date: date + 180, request: "And the budget?", reply: "About €300 with food. Pack light."))
        imp.showSample(chat)
        let steps = [Bubble.Step(icon: "hammer", title: "Files › search", state: .done),
                     Bubble.Step(icon: "hammer", title: "Calendar › list events", state: .running)]
        let samples = [
            Bubble(phase: .typing),
            Bubble(phase: .typing, prompt: "I didn't catch that. Type it?"),
            Bubble(text: "What's the weather like in", phase: .listening),
            Bubble(title: "“What's on my calendar tomorrow?”", text: "Bribing the server…", phase: .thinking, steps: steps),
            Bubble(title: "Talk to Imp", text: "Tomorrow you have a dentist at 10 and lunch with Sam at 1. Brush twice.",
                   phase: .result, steps: steps.map { var s = $0; s.state = .done; return s }),
            Bubble(title: "Translate", text: "Привет! Как дела?", phase: .result),
            Bubble(title: "Talk to Imp", text: """
                ### Packing list
                **Weekend** in *Lisbon*, run `trip --dry`:
                1. Passport
                2. Charger
                   - USB-C
                - Snacks

                | Item | Qty | Price |
                |:--|:-:|--:|
                | Pastel de nata | 6 | €7.20 |
                | Coffee | 2 | €2.40 |
                """, phase: .result),
            Bubble(title: "Oops: Translate a picture", text: "Out of credits (402). Imps work for gold.", phase: .error, link: .settings),
        ]
        // A long reply, cut short and then read in full.
        let long = Bubble(title: "Talk to Imp", text: (1...14).map {
            "Paragraph \($0): imps keep their replies short, but sometimes a question deserves a proper answer with a few details."
        }.joined(separator: "\n\n"), phase: .result)
        let collapsed = layout.copy(), expanded = layout.copy()
        collapsed.textLimit = 210
        expanded.expanded = true
        expanded.textLimit = 300
        let tiny = layout.copy()                       // resized by hand to something small
        tiny.expanded = true
        tiny.customWidth = 260
        tiny.customTextHeight = 80
        tiny.textLimit = 80
        // A finished job, its steps listed and one opened to its request and response.
        var command = Bubble.Step(icon: "terminal", title: "sips -s format png in.heic --out picture.png", state: .done, tool: ShellTool.name)
        command.request = "sips -s format png in.heic --out picture.png"
        command.response = "/Users/me/in.heic\n  /Users/me/picture.png"
        let worked = Bubble(title: "Talk to Imp", text: "Done. Picture: [picture.png](picture.png)", phase: .result,
                            steps: [command, Bubble.Step(icon: "hammer", title: "Images › edit image", state: .done, tool: "images__edit")])
        let opened = layout.copy()
        opened.showSteps = true
        opened.openSteps = [command.id]
        let sheet = HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, b in
                    BubbleCard(bubble: b, model: imp, layout: layout, measuring: true)
                }
            }
            VStack(spacing: 0) {
                BubbleCard(bubble: long, model: imp, layout: collapsed, measuring: true)
                BubbleCard(bubble: long, model: imp, layout: expanded, measuring: true)
                BubbleCard(bubble: long, model: imp, layout: tiny, measuring: true)
                BubbleCard(bubble: worked, model: imp, layout: opened, measuring: true)
                BubbleCard(bubble: Bubble(phase: .chat), model: imp, layout: layout, measuring: true)
                BubbleCard(bubble: Bubble(title: "Talk to Imp", text: "Said it out loud:\n\n![Voice reply](reply.mp3#autoplay)\n\n![The clip](clip.mov)",
                                          phase: .result), model: imp, layout: layout, measuring: true)
            }
        }
        let host = NSHostingView(rootView: sheet)
        host.frame.size = host.fittingSize
        snapshot(host, to: url, dark: dark)
    }

    private static func snapshot(_ view: NSView, to url: URL, dark: Bool) {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: view.frame.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.9, alpha: 1)
        window.contentView = view
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let content = window.contentView?.superview ?? window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private struct AppIcon: View {
        var body: some View {
            GeometryReader { geo in
                let s = geo.size.width
                ZStack {
                    RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.995, green: 0.975, blue: 0.945), Color(red: 0.95, green: 0.91, blue: 0.86)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(s * 0.098)
                        .shadow(color: .black.opacity(0.22), radius: s * 0.02, y: s * 0.01)
                    // The character spans ~66% of its canvas. This makes the head about 70% of the tile,
                    // centred on its visual middle (horn tips to base).
                    ImpPortrait(face: .settled(.idle, lookX: 0.22, lookY: 0.05))
                        .frame(width: s * 1.06, height: s * 1.06)
                        .offset(y: -s * 0.095)
                }
            }
        }
    }

    /// `Imp --render-egg <file.png>`: a filmstrip of the egg hatching (idle, then every ~100 ms).
    static func renderEgg(to url: URL) {
        let times: [Double?] = [nil, 0.2, 0.4, 0.55, 0.68, 0.76, 0.84, 0.92, 1.02, 1.14, 1.3, 1.5]
        let strip = Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<6, id: \.self) { col in
                        let t = times[row * 6 + col]
                        VStack(spacing: 2) {
                            ImpEgg(elapsed: t).frame(width: 150, height: 190)
                            Text(t.map { String(format: "%.2f s", $0) } ?? "idle")
                                .font(.system(size: 12, design: .rounded)).foregroundStyle(Dungeon.muted)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Dungeon.wall)
        write(render(strip, scale: 2), to: url)
    }

    /// The installer window: the dungeon wall, a glow where Imp's icon sits, an ember arrow to
    /// Applications, and name tags. Sizes and centres match scripts/dmg-settings.py.
    private struct DMGBackground: View {
        static let size = CGSize(width: 660, height: 400)
        static let app = CGPoint(x: 170, y: 180)
        static let applications = CGPoint(x: 490, y: 180)

        var body: some View {
            ZStack {
                DungeonBackdrop(quiet: true)
                Canvas { ctx, _ in
                    let glow = Gradient(colors: [Dungeon.ember.opacity(0.35), .clear])
                    ctx.fill(Path(ellipseIn: CGRect(x: Self.app.x - 120, y: Self.app.y - 120, width: 240, height: 240)),
                             with: .radialGradient(glow, center: Self.app, startRadius: 0, endRadius: 120))
                    Self.arrow(&ctx)
                    // Cream name tags under the icons. Finder draws the names itself (dark, on a
                    // picture background) and can't recolour or hide them, so they get a light tag.
                    for (centre, width) in [(Self.app, 84.0), (Self.applications, 132.0)] {
                        let tag = CGRect(x: centre.x - width / 2, y: centre.y + 60, width: width, height: 34)
                        ctx.fill(Path(roundedRect: tag, cornerRadius: 17), with: .color(Dungeon.cream.opacity(0.92)))
                    }
                }
                Text("Drag Imp to Applications")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 34)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, .dark)
        }

        /// A dashed arc between the two icons, with a rounded head.
        private static func arrow(_ ctx: inout GraphicsContext) {
            let start = CGPoint(x: app.x + 92, y: app.y - 6)
            let end = CGPoint(x: applications.x - 92, y: applications.y - 6)
            let control = CGPoint(x: (start.x + end.x) / 2, y: start.y - 46)
            var arc = Path()
            arc.move(to: start)
            arc.addQuadCurve(to: end, control: control)
            ctx.stroke(arc, with: .color(Dungeon.ember), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2, 12]))

            // The head points along the curve's last stretch (from the control point to the end).
            let angle = atan2(end.y - control.y, end.x - control.x)
            var head = Path()
            for side in [-1.0, 1.0] {
                let a = angle + .pi - side * .pi / 5
                head.move(to: end)
                head.addLine(to: CGPoint(x: end.x + 16 * cos(a), y: end.y + 16 * sin(a)))
            }
            ctx.stroke(head, with: .color(Dungeon.ember), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
    }

    private static func render(_ view: some View, scale: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: view)
        r.scale = scale
        return r.cgImage
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
