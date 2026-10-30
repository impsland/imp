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

    /// `Imp --render-ios-icon <file.png>`: the iPhone app's icon (iOS/scripts/make-icon.sh). The
    /// Mac icon's tile and Imp, full bleed and opaque: iOS cuts its own corners and refuses alpha.
    static func renderIOSIcon(to url: URL) {
        guard let image = render(AppIcon(fullBleed: true).frame(width: 1024, height: 1024), scale: 1),
              let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        write(ctx.makeImage(), to: url)
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

    /// `Imp --render-animation <reaction> <file.png> [trait preset]`: a filmstrip of an animation as the
    /// desktop Imp plays it (springs, hops, glyphs), every 80 ms, each frame outlined so clipping shows.
    static func renderAnimation(_ reaction: Reaction, traits: ImpTraits, to url: URL) {
        let puppet = Puppet()
        let performance = Performance(key: reaction.rawValue, steps: Antics.paced(Antics.steps(for: reaction, work: .zero), tempo: traits.tempo),
                                      at: Date(timeIntervalSinceReferenceDate: 0))
        var frames: [(Face, Motion, Performance.Beat?)] = []
        let fps = 60.0, every = 5
        var i = 0
        while Double(i) / fps < performance.duration + 0.5 {
            let date = Date(timeIntervalSinceReferenceDate: Double(i) / fps)
            let beat = performance.beat(at: date)
            let cue = Puppet.Cue(mood: beat?.step.mood ?? .idle, step: beat?.step, hue: 0.57, hopSince: beat?.hopSince,
                                 stepElapsed: beat?.elapsed, traits: traits)
            let (face, motion) = puppet.frame(cue, at: Double(i) / fps)
            if i % every == 0 { frames.append((face, motion, beat)) }
            i += 1
        }
        let columns = 10, cell: CGFloat = 112
        let sheet = Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(stride(from: 0, to: frames.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, frames.count), id: \.self) { k in
                        let (face, motion, beat) = frames[k]
                        Canvas { ctx, size in
                            ImpRenderer.draw(&ctx, size: size, face: face, motion: motion, glyph: beat?.glyph?.glyph,
                                             glyphAge: beat?.glyph?.age ?? 0, glyphFade: (beat?.glyph?.remaining ?? 0) / 0.5)
                        }
                        .frame(width: cell, height: cell)
                        .border(Color.black.opacity(0.25), width: 1)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(red: 0.99, green: 0.98, blue: 0.96))
        write(render(sheet, scale: 2), to: url)
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
    /// (`looks`, `brain`, `tools`, `shortcuts`), `general-<tab>`, or the `add-service` / `add-tool` / `add-shortcut` / `edit-shortcut` / `animation-editor` / `animation-details` sheets. `hidden=1`: the desktop Imps are hidden.
    static func renderHome(screen: String, to url: URL, width: CGFloat = 780, height: CGFloat = 600, sampleImps: Int = 1, select: Int = 0, out: Int? = nil, away: Int? = nil, hidden: Bool = false) {
        let model = AppModel(persist: false)          // review renders never write the user's preferences
        model.prefs = ImpPreferences()
        for _ in 1..<max(1, sampleImps) { model.addImp() }
        let ids = model.prefs.imps.map(\.id)
        let chosen = ids[min(max(select, 0), ids.count - 1)]
        if sampleImps > 1, let i = model.prefs.imps.indices.dropFirst().first {
            // Something to look at: a trigger and an extra tool.
            var a = Shortcut(name: "Translate", hotkey: Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: Hotkey.control | Hotkey.option),
                              prompt: "Translate this into English.")
            a.performer = model.prefs.imps[i].id
            model.prefs.shortcuts = [a]
            let files = MCPExamples.all[0]
            model.prefs.mcpServers = [files]
            model.prefs.imps[i].servers = [files.id]
            model.prefs.ai.add(Service(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "some/model"))
            model.prefs.ai.add(Service(name: "Ollama", baseURL: "http://localhost:11434/v1", model: "llama3.2"))
        }
        if let out, model.prefs.imps.indices.contains(out) { model.prefs.imps[out].isActive = true }
        if let away, model.prefs.imps.indices.contains(away) {
            model.prefs.imps[away].isActive = true
            model.prefs.imps[away].awayOn = UUID()
        }
        if hidden { model.setHidden(true) }
        let router = HomeRouter()
        router.selection = chosen
        switch screen {
        case "home": router.screen = .home
        case "egg": router.screen = .home; router.selection = nil
        case let s where s.hasPrefix("general-"):
            router.screen = .general
            router.generalTab = GeneralTab(rawValue: String(s.dropFirst(8))) ?? .services
        default:
            router.screen = .imp(chosen)
            router.impTab = ImpTab.allCases.first { $0.rawValue == screen || $0.title.lowercased() == screen } ?? .looks
        }
        let root: AnyView = switch screen {
        case "add-service": AnyView(AddServiceSheet(model: model) { _ in }.background(Color(nsColor: .windowBackgroundColor)))
        case "add-tool": AnyView(ServerEditor(draft: MCPExamples.examples.first { !$0.isComplete }!.server,
                                                  isNew: true, hub: model.assistant.hub) { _ in }
            .background(Color(nsColor: .windowBackgroundColor)))
        case "animation-editor", "animation-details":
            AnyView(AnimationEditor(model: model, draft: .replacing(.cheer, owner: nil, model: model, previewImp: chosen),
                                    page: screen == "animation-details" ? .details : .edit)
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

    /// `Imp --render-kit <file.png> [entry]`: the sheet for adding a kit (its review, or the text box).
    static func renderKit(to url: URL, entry: Bool) {
        let model = AppModel(persist: false)
        model.prefs = ImpPreferences()
        model.addImp()
        let first = model.prefs.imps[0]
        let json = #"""
        { "imp": 2, "app": "1.7.0", "name": "Morning helper", "about": "Starts the day: a plan when the Mac wakes up, a summary on a key, and a notes tool.",
          "imps": [
            { "name": "Pip", "hue": 0.57, "favoriteHue": 0.9, "scale": 1,
              "personality": "A dry-witted morning companion. Short answers, one gentle joke, never before coffee.",
              "brain": { "model": "gpt-4o", "service": { "name": "OpenAI", "baseURL": "https://api.openai.com/v1" } },
              "shell": true, "tools": { "body": true, "senses": true, "setup": false, "troupe": true, "computer": true },
              "mcpServers": ["Notes"],
              "triggers": [ { "name": "Good morning", "when": {"kind": "start"}, "prompt": "Greet me and say what's on today." } ],
              "chats": [ { "title": "Plan the week", "turns": [ { "request": "Plan my week", "reply": "Mon: focus. Tue: calls." } ] },
                         { "title": "Lunch", "turns": [ { "request": "Lunch?", "reply": "Soup." } ] } ] },
            { "name": "Nib", "hue": 0.25, "personality": "Terse and practical." }
          ],
          "triggers": [
            { "name": "Plan my day", "when": {"kind": "wake"}, "only_if": [{"kind": "hours", "text": "06:00-11:00"}], "prompt": "Look at my calendar and reminders for today and give me a short plan." },
            { "name": "Summarize", "when": {"kind": "keys", "keys": "ctrl+cmd+S"}, "prompt": "Summarize this in two or three short sentences.", "with_clipboard": true },
            { "name": "Bad one", "when": {"kind": "teleport"} }
          ],
          "mcpServers": {
            "Notes": { "command": "npx", "args": ["-y", "@example/notes-mcp"], "env": {"NOTES_TOKEN": ""} },
            "Weather": { "url": "https://mcp.example.com/weather" }
          } }
        """#
        model.prefs.shortcuts.append(Shortcut(name: "Mine", hotkey: Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: Hotkey.control | Hotkey.command), prompt: "x"))
        let flow = KitFlow(imp: first.id, text: entry ? "" : json)
        if !entry, let kit = try? Kit.parse(json) {
            flow.review = KitReview(kit: kit, origin: "example.com", existing: model.prefs.shortcuts, services: model.prefs.ai.services, target: nil)
        } else if entry {
            flow.error = KitError.newerVersion(3).localizedDescription
        }
        let tint = Color.imp(first.hue)
        let root = KitFlowSheet(model: model, flow: flow, router: HomeRouter())
            .environment(\.impTint, tint).tint(tint)
            .environment(\.sheetRoom, 760)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(x: -3000, y: -3000, width: 540, height: max(size.height, 200)),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        window.setContentSize(host.fittingSize)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
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
                // Nothing but a voice: the puff of smoke is the answer.
                BubbleCard(bubble: Bubble(title: "Talk to Imp", text: "![Voice reply](reply.mp3#autoplay)", phase: .result),
                           model: imp, layout: layout, measuring: true)
                // Several voice notes (they play in turn) (they play in turn), two clips side by side in the text.
                BubbleCard(bubble: Bubble(title: "Voice notes", text: "Three parts:\n\n- Intro ![Part 1](1.mp3#autoplay)\n- ![Part 2](2.mp3#autoplay)\n- Outro ![Part 3](3.m4a#autoplay)\n\n![Before](a.mp4) ![After](b.mov)\n\n> Note ![Waveform](w.png)",
                                          phase: .result), model: imp, layout: layout, measuring: true)
            }
        }
        let host = NSHostingView(rootView: sheet)
        host.frame.size = host.fittingSize
        snapshot(host, to: url, dark: dark)
    }

    /// `Imp --render-exchange <file.png> [dark]`: bubbles and chat for Imps talking to each other.
    static func renderExchange(to url: URL, dark: Bool) {
        let model = AppModel(persist: false)
        let imp = ImpModel(id: model.prefs.imps[0].id, app: model)
        let layout = BubbleLayout()
        let pip = ChatTurn.Sender(id: UUID(), name: "Pip", hue: 0.58), mo = ChatTurn.Sender(id: UUID(), name: "Mo", hue: 0.33)
        let question = "Can you check whether the user has anything on tomorrow afternoon? They asked me to plan a picnic."
        var chat = ChatHistory(folder: nil)
        let date = Date(timeIntervalSinceReferenceDate: 812_000_000)
        chat.append(ChatTurn(date: date, request: "Plan a picnic", reply: "Let me ask Pip about the calendar."))
        chat.append(ChatTurn(date: date + 60, request: question, reply: "Tomorrow after 3 pm is free. Sunny, too.", via: .imp, sender: pip))
        chat.append(ChatTurn(date: date + 120, request: "Do you have a basket?", reply: "Two. One has a squeaky lid.", via: .imp, sender: mo))
        imp.showSample(chat)
        let steps = [Bubble.Step(icon: "person.2.fill", title: "Message Mo", state: .running, tool: OwnTools.message)]
        func exchange(_ role: Bubble.Exchange.Role, _ peer: ChatTurn.Sender, _ q: String = question) -> Bubble.Exchange {
            Bubble.Exchange(role: role, peer: peer, question: q)
        }
        var asked = Bubble(text: "Plotting quietly…", phase: .thinking)
        asked.exchange = exchange(.asked, pip)
        var askedShort = Bubble(text: "Borrowing a brain…", phase: .thinking)
        askedShort.exchange = exchange(.asked, mo, "Do you have a basket?")
        var asking = Bubble(text: "Stirring the cauldron…", phase: .thinking, steps: steps)
        asking.exchange = exchange(.asking, mo, "Do you have a basket for a picnic?")
        var reply = Bubble(text: "Tomorrow after 3 pm is free. Sunny, too. Shall I tell the user?", phase: .result)
        reply.exchange = exchange(.reply, pip)
        var asked2 = Bubble(text: "Borrowing a brain…", phase: .thinking)
        asked2.exchange = exchange(.asked, pip, "Hi!")
        let sheet = HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                BubbleCard(bubble: asked, model: imp, layout: layout, measuring: true)
                BubbleCard(bubble: askedShort, model: imp, layout: layout, measuring: true)
                BubbleCard(bubble: asking, model: imp, layout: layout, measuring: true)
                BubbleCard(bubble: reply, model: imp, layout: layout, measuring: true)
            }
            BubbleCard(bubble: Bubble(phase: .chat), model: imp, layout: layout, measuring: true)
        }
        let host = NSHostingView(rootView: sheet)
        host.frame.size = host.fittingSize
        snapshot(host, to: url, dark: dark)
    }

    /// `Imp --render-voice <file.png> [dark]`: a speaking bubble's glow and smoke for a few Imp
    /// colours, resting and at rising loudness (a plain card stands in for the glass).
    static func renderVoice(to url: URL, dark: Bool) {
        let moments: [(String, VoiceNow)] = [("resting", VoiceNow(media: nil, playing: false, level: 0)),
                                             ("soft", VoiceNow(media: nil, playing: true, level: 0.25)),
                                             ("loud", VoiceNow(media: nil, playing: true, level: 0.95))]
        let card = dark ? Color(white: 0.2) : Color(white: 0.97)
        let sheet = Grid(horizontalSpacing: 36, verticalSpacing: 40) {
            ForEach([0.0, 0.58, 0.78, 0.33], id: \.self) { hue in
                GridRow {
                    ForEach(moments.indices, id: \.self) { i in
                        let look = VoiceLook(hue: hue), moment = (t: Double(i) * 1.7 + hue * 10, now: moments[i].1)
                        VStack(spacing: 14) {
                            Text("Said it out loud: the weekend in Lisbon, in a minute.")
                                .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                            VoiceOrb(look: look, owner: "", size: 56, preview: moment)
                        }
                        .padding(14)
                        .frame(width: 260)
                        .background {
                            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(card)
                            VoiceAura(look: look, owner: "", preview: moment)
                        }
                        .overlay(alignment: .top) { VoiceOrb(look: look, owner: "", preview: moment).offset(y: -13) }
                        .overlay(alignment: .bottom) { Text(moments[i].0).font(.caption).foregroundStyle(.secondary).offset(y: 22) }
                    }
                }
            }
        }
        .padding(40)
        .background(dark ? Color(white: 0.12) : Color(white: 0.88))
        .environment(\.colorScheme, dark ? .dark : .light)
        .foregroundStyle(dark ? .white : .black)
        write(render(sheet, scale: 2), to: url)
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
        /// The tile fills the whole square (iOS), instead of sitting inside macOS's icon grid.
        var fullBleed = false

        var body: some View {
            GeometryReader { geo in
                // The Mac tile is the canvas less a 9.8% margin; everything is sized off the tile.
                let tile = fullBleed ? geo.size.width : geo.size.width * (1 - 2 * 0.098)
                let fill = LinearGradient(colors: [Color(red: 0.995, green: 0.975, blue: 0.945), Color(red: 0.95, green: 0.91, blue: 0.86)],
                                          startPoint: .top, endPoint: .bottom)
                ZStack {
                    if fullBleed {
                        Rectangle().fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: tile * 0.28, style: .continuous).fill(fill)
                            .frame(width: tile, height: tile)
                            .shadow(color: .black.opacity(0.22), radius: tile * 0.025, y: tile * 0.012)
                    }
                    // The character spans ~66% of its canvas. This makes the head about 70% of the tile,
                    // centred on its visual middle (horn tips to base).
                    // Full bleed, a touch smaller: iOS rounds the corners off, and the horns must stay inside.
                    let k = fullBleed ? 1.2 : 1.318
                    ImpPortrait(face: .settled(.idle, lookX: 0.22, lookY: 0.05))
                        .frame(width: tile * k, height: tile * k)
                        .offset(y: -tile * k * 0.0895)
                }
                .frame(width: geo.size.width, height: geo.size.height)
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

    /// The installer window: the dungeon wall, Imp and Applications each standing on a stone plinth,
    /// and an ember arrow between them. Finder draws the names itself, in the system's text colour
    /// (black in Light Mode, white in Dark Mode), and its exact offset under the icon varies. So the
    /// names land on the plinth's face: big enough for any offset, in a stone of middle lightness
    /// that both black and white text read on (about 4.5:1 either way).
    /// Sizes and centres match scripts/dmg-settings.py.
    private struct DMGBackground: View {
        static let size = CGSize(width: 660, height: 400)
        static let app = CGPoint(x: 170, y: 176)
        static let applications = CGPoint(x: 490, y: 176)
        static let iconSize: CGFloat = 128
        /// The plinth's face, under each icon: room for the name a little higher or lower.
        static let plinth = CGSize(width: 196, height: 52)
        /// Relative luminance ≈ 0.18: the middle, where black and white text contrast equally.
        static let plinthFace = Color(red: 0.60, green: 0.41, blue: 0.46)
        static let plinthTop = Color(red: 0.72, green: 0.52, blue: 0.56)

        var body: some View {
            ZStack {
                DungeonBackdrop(quiet: true)
                Canvas { ctx, _ in
                    let glow = Gradient(colors: [Dungeon.ember.opacity(0.32), .clear])
                    ctx.fill(Path(ellipseIn: CGRect(x: Self.app.x - 130, y: Self.app.y - 130, width: 260, height: 260)),
                             with: .radialGradient(glow, center: Self.app, startRadius: 0, endRadius: 130))
                    for centre in [Self.app, Self.applications] { Self.plinth(&ctx, under: centre) }
                    Self.arrow(&ctx)
                }
                Text("Drag Imp to Applications")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Dungeon.muted)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, .dark)
        }

        /// A stone block the icon stands on: a lit top edge, then the face the name is written on.
        private static func plinth(_ ctx: inout GraphicsContext, under centre: CGPoint) {
            let top = centre.y + iconSize / 2 - 10
            let face = CGRect(x: centre.x - plinth.width / 2, y: top, width: plinth.width, height: plinth.height)
            var shadow = ctx
            shadow.addFilter(.blur(radius: 10))
            shadow.fill(Path(roundedRect: face.offsetBy(dx: 0, dy: 8), cornerRadius: 14), with: .color(.black.opacity(0.45)))
            ctx.fill(Path(roundedRect: face, cornerRadius: 14), with: .color(plinthFace))
            ctx.fill(Path(roundedRect: CGRect(x: face.minX, y: face.minY, width: face.width, height: 6), cornerRadius: 3),
                     with: .color(plinthTop))
            ctx.stroke(Path(roundedRect: face.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 14),
                       with: .color(.white.opacity(0.14)), lineWidth: 1)
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
