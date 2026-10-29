import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ImpKit
import ScreenCaptureKit

/// Operates other apps for an Imp: reads a window's accessibility tree, takes its screenshot, and
/// clicks, types and drags. One per Imp, so each keeps its own last look (what `computer_act` and
/// `computer_verify` compare with). Everything runs on the main actor.
///
/// Coordinates: see `ComputerSpace`. AX positions and CGEvent locations are global points
/// (top-left origin); the model works in screenshot pixels, converted here and nowhere else.
@MainActor
final class ComputerControl {
    /// Something to tell the model (shown as "Error: …").
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// An observation's picture and text.
    struct Look { var snapshot: ComputerSnapshot; var image: EncodedImage? }

    private var ids = ComputerElementIDs()
    private var refs: [String: AXUIElement] = [:]
    private var last: ComputerSnapshot?
    private var space: ComputerSpace?
    private var app: NSRunningApplication?
    private var window: AXUIElement?
    private var windowSerial = 0
    /// Caps on what an observation lists.
    static let maxElements = 300
    static let maxVisited = 2_500

    // MARK: Permissions

    /// The model's error for a missing permission, if any.
    static func missingPermission(needsScreen: Bool) -> String? {
        ComputerTools.permissionError(screen: needsScreen && !CGPreflightScreenCaptureAccess(), accessibility: !AXIsProcessTrusted())
    }

    // MARK: Observe

    func observe(app name: String?, window title: String?, screenshot: Bool = true) async throws -> Look {
        let target = try resolveApp(name)
        let pick = try pickWindow(of: target, matching: title)
        adopt(app: target, window: pick.window)
        return try await look(screenshot: screenshot, windows: pick.titles, chosen: pick.index)
    }

    /// Looks again at the window being operated (falling back to the app's focused window if it closed).
    private func relook(screenshot: Bool) async throws -> Look {
        guard let app else { throw Failure("Nothing observed yet. Call computer_observe first.") }
        if let window, AX.string(window, kAXRoleAttribute) == nil || AX.frame(window) == nil {
            let pick = try pickWindow(of: app, matching: nil)
            adopt(app: app, window: pick.window)
            return try await look(screenshot: screenshot, windows: pick.titles, chosen: pick.index)
        }
        let pick = try pickWindow(of: app, matching: nil, preferring: window)
        return try await look(screenshot: screenshot, windows: pick.titles, chosen: pick.index)
    }

    private func adopt(app: NSRunningApplication, window: AXUIElement) {
        if let old = self.window, CFEqual(old, window), self.app?.processIdentifier == app.processIdentifier { return }
        self.app = app; self.window = window; windowSerial += 1
    }

    private func look(screenshot: Bool, windows: [String], chosen: Int) async throws -> Look {
        guard let app, let window, let frame = AX.frame(window) else { throw Failure("The window is gone. Call computer_observe again.") }
        let space = ComputerSpace(windowFrame: frame)
        self.space = space
        let walked = walk(window: window, space: space)
        refs = walked.refs
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let menus = AX.elements(appElement, kAXMenuBarAttribute).first.map { bar in
            AX.elements(bar, kAXChildrenAttribute).compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
        } ?? []
        var snapshot = ComputerSnapshot(
            app: app.localizedName ?? app.bundleIdentifier ?? "app", windowTitle: AX.string(window, kAXTitleAttribute) ?? "",
            windowKey: "\(app.processIdentifier)|\(windowSerial)",
            windows: windows.enumerated().map { ComputerWindow(title: $0.element, isTarget: $0.offset == chosen) },
            imageSize: space.imageSize, elements: walked.elements, omitted: walked.omitted, menus: menus)
        snapshot.windowTitle = snapshot.windowTitle.isEmpty ? "(untitled)" : snapshot.windowTitle
        last = snapshot
        var image: EncodedImage?
        if screenshot { image = try await capture(space: space, pid: app.processIdentifier) }
        return Look(snapshot: snapshot, image: image)
    }

    // MARK: Act

    func act(_ action: ComputerAction) async throws -> (text: String, image: EncodedImage?) {
        guard let app, let window, last != nil else { throw Failure("Nothing observed yet. Call computer_observe first.") }
        guard let frame = AX.frame(window), var space else { throw Failure("The window is gone. Call computer_observe again.") }
        space.windowFrame.origin = frame.origin   // the window may have moved since the last look
        self.space = space
        await bringToFront(app, window)
        let before = last
        var notes: [String] = []
        try await perform(action, space: space, notes: &notes)
        try? await Task.sleep(for: .milliseconds(450))
        let after = try await relook(screenshot: action.observe)
        var lines = notes
        if let before, let diff = after.snapshot.changes(since: before) {
            lines.append("Done: \(action.kind.rawValue). Changes since the last look:\n\(diff)")
        } else {
            lines.append("Done: \(action.kind.rawValue). The window is now different.\n\(after.snapshot.render())")
        }
        if action.observe { lines.append("A fresh screenshot is attached (\(Int(after.snapshot.imageSize.width))x\(Int(after.snapshot.imageSize.height)) px).") }
        return (lines.joined(separator: "\n"), after.image)
    }

    func verify(condition: String) async throws -> (text: String, image: EncodedImage?) {
        if app == nil { throw Failure("Nothing observed yet. Call computer_observe first.") }
        let before = last
        try? await Task.sleep(for: .milliseconds(300))
        let now = try await relook(screenshot: true)
        let changes = before.flatMap { now.snapshot.changes(since: $0) } ?? "The window is different from your last look; here it is:\n\(now.snapshot.render())"
        return ("""
            Condition to check: \(condition)
            Window now: \(now.snapshot.app), “\(now.snapshot.windowTitle)”. Changes since your last look:
            \(changes)
            Judge the condition honestly from the attached screenshot: say whether it is met or not met, and why. \
            If it isn't met, don't claim it is: fix it or tell the user.
            """, now.image)
    }

    private func perform(_ a: ComputerAction, space: ComputerSpace, notes: inout [String]) async throws {
        switch a.kind {
        case .click, .doubleClick, .rightClick, .hover, .focus, .press:
            let t = try resolve(a.target, space: space, notes: &notes)
            try await pointerAction(a.kind, t)
        case .type:
            if let target = a.target {
                let t = try resolve(target, space: space, notes: &notes)
                try await focus(t)
            }
            await Input.type(a.value ?? "")
        case .setValue:
            let t = try resolve(a.target, space: space, notes: &notes)
            guard let el = t.element else { throw Failure("set_value needs an element, not coordinates.") }
            try setValue(a.value ?? "", on: el)
        case .key:
            guard let keys = a.keys else { throw Failure("No key given.") }
            await Input.key(keys)
        case .scroll:
            let at = a.target == nil ? CGPoint(x: space.windowFrame.midX, y: space.windowFrame.midY)
                                     : try resolve(a.target, space: space, notes: &notes).point
            await Input.scroll(at: at, dx: a.dx, dy: a.dy)
        case .drag:
            var points: [CGPoint] = []
            if a.target != nil { points.append(try resolve(a.target, space: space, notes: &notes).point) }
            points += try (a.path + (a.to.map { [$0] } ?? [])).map { try global($0, space) }
            guard points.count >= 2 else { throw Failure("drag needs a start and an end.") }
            await Input.drag(points)
        case .select:
            if let menuPath = a.menuPath {
                try await selectMenu(menuPath)
            } else {
                let t = try resolve(a.target, space: space, notes: &notes)
                try await selectOption(a.value ?? "", from: t)
            }
        }
    }

    // MARK: Targets

    struct Resolved {
        var element: AXUIElement?
        /// Global points: the element's centre, or the point.
        var point: CGPoint
    }

    private func global(_ p: CGPoint, _ space: ComputerSpace) throws -> CGPoint {
        guard space.containsImage(p) else {
            throw Failure("(\(Int(p.x)), \(Int(p.y))) is outside the window's screenshot (\(Int(space.imageSize.width))x\(Int(space.imageSize.height)) px).")
        }
        return space.global(fromImage: p)
    }

    private func resolve(_ target: ComputerTarget?, space: ComputerSpace, notes: inout [String]) throws -> Resolved {
        switch target {
        case nil: throw Failure("This action needs a target.")
        case .point(let p)?: return Resolved(element: nil, point: try global(p, space))
        case .element(let id)?: return try resolveElement(id)
        case .text(let text)?:
            let found = last?.find(text) ?? []
            guard let first = found.first else {
                throw Failure("No element is named “\(text)” in the last observation. Observe again, or use an element id or x,y coordinates.")
            }
            if found.count > 1 { notes.append("Note: \(found.count) elements match “\(text)”; used \(first.id) (others: \(found.dropFirst().prefix(4).map(\.id).joined(separator: ", "))).") }
            return try resolveElement(first.id)
        }
    }

    private func resolveElement(_ id: String) throws -> Resolved {
        guard let el = refs[id] else { throw Failure("Unknown element \(id). Ids come from the latest computer_observe; observe again.") }
        guard let frame = AX.frame(el), frame.width > 0, frame.height > 0 else {
            throw Failure("Element \(id) is gone or has no size now. Observe again.")
        }
        return Resolved(element: el, point: CGPoint(x: frame.midX, y: frame.midY))
    }

    private func pointerAction(_ kind: ComputerAction.Kind, _ t: Resolved) async throws {
        let actions = t.element.map(AX.actions) ?? []
        switch kind {
        case .press:
            guard let el = t.element, actions.contains(kAXPressAction) else {
                throw Failure("It can't be pressed" + (actions.isEmpty ? "." : " (it supports: \(actions.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ", "))). Try click."))
            }
            guard AX.perform(el, kAXPressAction) else { throw Failure("Pressing it failed. Try click.") }
        case .click:
            if let el = t.element, actions.contains(kAXPressAction), AX.perform(el, kAXPressAction) { return }
            await Input.click(at: t.point)
        case .doubleClick: await Input.click(at: t.point, count: 2)
        case .rightClick:
            if let el = t.element, actions.contains(kAXShowMenuAction), AX.perform(el, kAXShowMenuAction) { return }
            await Input.click(at: t.point, right: true)
        case .hover: await Input.move(to: t.point)
        case .focus: try await focus(t)
        default: break
        }
    }

    private func focus(_ t: Resolved) async throws {
        if let el = t.element, AX.set(el, kAXFocusedAttribute, kCFBooleanTrue), AX.bool(el, kAXFocusedAttribute) == true { return }
        await Input.click(at: t.point)
    }

    private func setValue(_ text: String, on el: AXUIElement) throws {
        guard AX.isSettable(el, kAXValueAttribute) else { throw Failure("Its value can't be set. Use type (after focus) instead.") }
        let current = AX.value(el, kAXValueAttribute)
        let new: CFTypeRef = (current as? NSNumber != nil && Double(text) != nil) ? NSNumber(value: Double(text)!) : text as CFString
        guard AX.set(el, kAXValueAttribute, new) else { throw Failure("The app refused that value.") }
    }

    // MARK: Menus and options

    private func selectMenu(_ path: [String]) async throws {
        guard let app else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = AX.elements(appElement, "AXMenuBar").first else { throw Failure("\(app.localizedName ?? "The app") has no menu bar to use.") }
        var container = bar
        for (i, part) in path.enumerated() {
            let items = AX.elements(container, kAXChildrenAttribute)
            guard let item = Self.best(items, named: part) else {
                let names = items.compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
                _ = await Input.key(Hotkey(keyCode: UInt32(kVK_Escape)))
                throw Failure("No menu item “\(part)”. Available: \(names.prefix(30).joined(separator: ", ")).")
            }
            guard AX.perform(item, kAXPressAction) else { throw Failure("Couldn't press menu item “\(part)”.") }
            if i < path.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let menu = AX.elements(item, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == "AXMenu" }) else {
                    throw Failure("“\(part)” has no submenu.")
                }
                container = menu
            }
        }
    }

    private func selectOption(_ option: String, from t: Resolved) async throws {
        try await pointerAction(.click, t)
        try? await Task.sleep(for: .milliseconds(300))
        var roots: [AXUIElement] = []
        if let el = t.element { roots.append(el) }
        if let app { roots.append(AXUIElementCreateApplication(app.processIdentifier)) }
        var seen: [String] = []
        for root in roots {
            var items: [AXUIElement] = []
            Self.collect(root, role: "AXMenuItem", into: &items, depth: 0, limit: 200)
            if let item = Self.best(items, named: option) {
                guard AX.perform(item, kAXPressAction) else { throw Failure("Couldn't choose “\(option)”.") }
                return
            }
            seen += items.compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
        }
        await Input.key(Hotkey(keyCode: UInt32(kVK_Escape)))
        throw Failure("No option “\(option)”." + (seen.isEmpty ? " No menu opened: try click on it and observe." : " Options: \(seen.prefix(30).joined(separator: ", "))."))
    }

    /// The item whose title is `name` (ignoring case and a trailing …), else starts with, else contains.
    private static func best(_ items: [AXUIElement], named name: String) -> AXUIElement? {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "…", with: "").lowercased() }
        let q = clean(name)
        let titled = items.compactMap { item in AX.string(item, kAXTitleAttribute).map { (item, clean($0)) } }
        return titled.first { $0.1 == q }?.0 ?? titled.first { $0.1.hasPrefix(q) && !q.isEmpty }?.0 ?? titled.first { $0.1.contains(q) && !q.isEmpty }?.0
    }

    private static func collect(_ el: AXUIElement, role: String, into out: inout [AXUIElement], depth: Int, limit: Int) {
        guard depth < 6, out.count < limit else { return }
        for child in AX.elements(el, kAXChildrenAttribute) {
            if AX.string(child, kAXRoleAttribute) == role { out.append(child) }
            collect(child, role: role, into: &out, depth: depth + 1, limit: limit)
        }
    }

    // MARK: Apps and windows

    private func resolveApp(_ name: String?) throws -> NSRunningApplication {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let q = name.lowercased()
            let found = apps.first { $0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q }
                ?? apps.first { $0.localizedName?.lowercased().contains(q) == true || $0.bundleIdentifier?.lowercased().contains(q) == true }
            guard let found else {
                throw Failure("No running app matches “\(name)”. Running apps: \(apps.compactMap(\.localizedName).sorted().joined(separator: ", ")).")
            }
            return found
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me, front.activationPolicy == .regular { return front }
        // Imp itself is in front: take the app whose window is topmost.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me, let app = apps.first(where: { $0.processIdentifier == pid }) { return app }
        }
        throw Failure("No app is in front. Name one with `app`. Running apps: \(apps.compactMap(\.localizedName).sorted().joined(separator: ", ")).")
    }

    /// The app's usable windows, and the one wanted: by number or title, else `preferring`, else the focused one.
    private func pickWindow(of app: NSRunningApplication, matching title: String?, preferring: AXUIElement? = nil)
        throws -> (window: AXUIElement, titles: [String], index: Int) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 2)
        let all = AX.elements(element, kAXWindowsAttribute).filter { w in
            guard let f = AX.frame(w), f.width > 1, f.height > 1 else { return false }
            return AX.bool(w, kAXMinimizedAttribute) != true
        }
        guard !all.isEmpty else {
            throw Failure("\(app.localizedName ?? "The app") has no open window I can see (it may be hidden, minimized or on another desktop). Open or show a window first.")
        }
        let titles = all.map { AX.string($0, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? "(untitled)" }
        var index: Int?
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            if let n = Int(title), (1...all.count).contains(n) { index = n - 1 }
            else { index = titles.firstIndex { $0.lowercased() == title.lowercased() } ?? titles.firstIndex { $0.lowercased().contains(title.lowercased()) } }
            guard index != nil else { throw Failure("No window of \(app.localizedName ?? "the app") matches “\(title)”. Windows: \(titles.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")).") }
        } else if let preferring, let i = all.firstIndex(where: { CFEqual($0, preferring) }) {
            index = i
        } else if let focused = AX.elements(element, kAXFocusedWindowAttribute).first ?? AX.elements(element, kAXMainWindowAttribute).first,
                  let i = all.firstIndex(where: { CFEqual($0, focused) }) {
            index = i
        }
        let i = index ?? 0
        return (all[i], titles, i)
    }

    private func bringToFront(_ app: NSRunningApplication, _ window: AXUIElement) async {
        if !app.isActive, let url = app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        _ = AX.set(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute, kCFBooleanTrue)
        _ = AX.perform(window, kAXRaiseAction)
        for _ in 0..<10 where !app.isActive { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Screenshot

    private func capture(space: ComputerSpace, pid: pid_t) async throws -> EncodedImage {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch { throw Failure("Couldn't list windows for the screenshot: \(error.localizedDescription)") }
        func distance(_ f: CGRect) -> CGFloat {
            abs(f.minX - space.windowFrame.minX) + abs(f.minY - space.windowFrame.minY)
                + abs(f.width - space.windowFrame.width) + abs(f.height - space.windowFrame.height)
        }
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
            .min(by: { distance($0.frame) < distance($1.frame) }), distance(window.frame) < 60 else {
            throw Failure("The window isn't visible on screen (hidden, minimized or on another desktop), so there's no screenshot.")
        }
        let config = SCStreamConfiguration()
        config.width = Int(space.imageSize.width)
        config.height = Int(space.imageSize.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) }
        catch { throw Failure("The screenshot failed: \(error.localizedDescription)") }
        guard let encoded = EncodedImage.encode(image, maxPixel: Int(ComputerSpace.maxLongSide)) else { throw Failure("Couldn't encode the screenshot.") }
        return encoded
    }

    // MARK: Tree

    private struct Walked { var elements: [ComputerElement] = []; var refs: [String: AXUIElement] = [:]; var omitted = 0; var visited = 0 }

    private static let interactive: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea",
        "AXSlider", "AXLink", "AXMenuItem", "AXIncrementor", "AXDisclosureTriangle", "AXColorWell", "AXTab", "AXSwitch",
        "AXSegmentedControl", "AXStepper", "AXToolbar", "AXSheet", "AXDialog", "AXDrawer", "AXPopover",
    ]
    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                     kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute,
                                     kAXSizeAttribute, kAXChildrenAttribute]

    private func walk(window: AXUIElement, space: ComputerSpace) -> Walked {
        var out = Walked()
        AXUIElementSetMessagingTimeout(window, 2)
        visit(window, key: "w", depth: 0, space: space, into: &out, isRoot: true)
        return out
    }

    /// Depth-first in reading order, so the caps cut off the end of the window, not the middle.
    private func visit(_ el: AXUIElement, key: String, depth: Int, space: ComputerSpace, into out: inout Walked, isRoot: Bool = false) {
        guard out.visited < Self.maxVisited else { return }
        out.visited += 1
        let a = AX.batch(el, Self.attributes)
        let role = (a[kAXRoleAttribute] as? String) ?? "AXUnknown"
        let frame = AX.frame(position: a[kAXPositionAttribute], size: a[kAXSizeAttribute])
        if !isRoot {
            guard let frame, frame.width > 0, frame.height > 0, frame.intersects(space.windowFrame) else { return }
        }
        func text(_ k: String) -> String { ((a[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var name = text(kAXTitleAttribute)
        if name.isEmpty { name = text(kAXDescriptionAttribute) }
        if name.isEmpty { name = text(kAXPlaceholderValueAttribute) }
        var value = ""
        if let v = a[kAXValueAttribute] {
            if let s = v as? String { value = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            else if let n = v as? NSNumber { value = n.stringValue }
        }
        if role == "AXStaticText", name.isEmpty { name = value; value = "" }
        if value == name { value = "" }
        let emit = !isRoot && (Self.interactive.contains(role) || !name.isEmpty || !value.isEmpty)
        var childDepth = depth
        if emit, let frame {
            if out.elements.count < Self.maxElements {
                let id = ids.id(for: key)
                let sub = text(kAXSubroleAttribute).replacingOccurrences(of: "AX", with: "")
                var shown = role.replacingOccurrences(of: "AX", with: "").lowercased()
                if !sub.isEmpty, !shown.contains(sub.lowercased()) { shown += "/" + sub.lowercased() }
                out.elements.append(ComputerElement(
                    id: id, role: shown, name: name, value: String(value.prefix(200)), enabled: (a[kAXEnabledAttribute] as? Bool) ?? true,
                    focused: (a[kAXFocusedAttribute] as? Bool) ?? false, frame: space.image(fromGlobal: frame), depth: min(depth, 12)))
                out.refs[id] = el
            } else { out.omitted += 1 }
            childDepth += 1
        }
        guard let children = a[kAXChildrenAttribute] as? [AXUIElement] else { return }
        var seen: [String: Int] = [:]
        for child in children.prefix(120) {
            let r = AX.string(child, kAXRoleAttribute) ?? "?"
            let n = String((AX.string(child, kAXTitleAttribute) ?? "").prefix(30))
            let tag = "\(r)[\(n)]"
            let i = seen[tag, default: 0]
            seen[tag] = i + 1
            visit(child, key: "\(key)/\(tag)#\(i)", depth: childDepth, space: space, into: &out)
        }
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func value(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ attribute: String) -> String? { value(el, attribute) as? String }
    static func bool(_ el: AXUIElement, _ attribute: String) -> Bool? { value(el, attribute) as? Bool }
    static func elements(_ el: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let v = value(el, attribute) else { return [] }
        if let list = v as? [AXUIElement] { return list }
        if CFGetTypeID(v) == AXUIElementGetTypeID() { return [v as! AXUIElement] }
        return []
    }
    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }
    @discardableResult static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }
    @discardableResult static func set(_ el: AXUIElement, _ attribute: String, _ v: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, attribute as CFString, v) == .success
    }
    static func isSettable(_ el: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Several attributes in one round trip; attributes that failed are left out.
    static func batch(_ el: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let list = result as? [AnyObject], list.count == names.count else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (name, item) in zip(names, list) {
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { continue }
            out[name] = item
        }
        return out
    }

    /// In global points (top-left origin).
    static func frame(_ el: AXUIElement) -> CGRect? { frame(position: value(el, kAXPositionAttribute), size: value(el, kAXSizeAttribute)) }

    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

// MARK: - Synthetic input

/// Mouse and keyboard events posted to the system (they go to the app in front, which `act` ensures).
@MainActor
enum Input {
    private static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
    private static func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    static func move(to p: CGPoint) async {
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        await pause(60)
    }

    static func click(at p: CGPoint, count: Int = 1, right: Bool = false) async {
        await move(to: p)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for n in 1...count {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                post(e)
                await pause(25)
            }
        }
    }

    static func drag(_ points: [CGPoint]) async {
        guard let first = points.first else { return }
        await move(to: first)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left))
        await pause(60)
        var here = first
        for target in points.dropFirst() {
            let distance = hypot(target.x - here.x, target.y - here.y)
            let steps = max(1, Int(min(distance / 10, 60)))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: here.x + (target.x - here.x) * t, y: here.y + (target.y - here.y) * t)
                post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
                await pause(6)
            }
            here = target
        }
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: here, mouseButton: .left))
        await pause(60)
    }

    /// `dy` > 0 scrolls down, `dx` > 0 to the right (wheel deltas are the other way round).
    static func scroll(at p: CGPoint, dx: Double, dy: Double) async {
        await move(to: p)
        let chunk = 200.0
        let steps = max(1, Int((max(abs(dx), abs(dy)) / chunk).rounded(.up)))
        for _ in 0..<steps {
            let x = Int32((-dx / Double(steps)).rounded()), y = Int32((-dy / Double(steps)).rounded())
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
            await pause(15)
        }
    }

    static func key(_ combo: Hotkey) async {
        var flags: CGEventFlags = []
        if combo.modifiers & Hotkey.command != 0 { flags.insert(.maskCommand) }
        if combo.modifiers & Hotkey.shift != 0 { flags.insert(.maskShift) }
        if combo.modifiers & Hotkey.option != 0 { flags.insert(.maskAlternate) }
        if combo.modifiers & Hotkey.control != 0 { flags.insert(.maskControl) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: down)
            e?.flags = flags
            post(e)
            await pause(15)
        }
    }

    /// Types text as Unicode key events (any layout); newline and tab are real keys.
    static func type(_ text: String) async {
        var buffer: [UniChar] = []
        func flush() async {
            guard !buffer.isEmpty else { return }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer)
                post(e)
            }
            buffer = []
            await pause(10)
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" { await flush(); await key(Hotkey(keyCode: UInt32(kVK_Return))); continue }
            if ch == "\t" { await flush(); await key(Hotkey(keyCode: UInt32(kVK_Tab))); continue }
            buffer += Array(String(ch).utf16)
            if buffer.count >= 16 { await flush() }
        }
        await flush()
    }
}

// MARK: - Command-line probe

/// `Imp --observe [app] [--screenshot file.png]`: prints what `computer_observe` would show, for trying
/// the permissions and the element tree without a model.
@MainActor
enum ComputerProbe {
    static func run(app: String?, screenshot: URL?) -> Never {
        _ = NSApplication.shared
        Task { @MainActor in
            if let problem = ComputerControl.missingPermission(needsScreen: screenshot != nil) {
                print(problem)
                exit(2)
            }
            do {
                let look = try await ComputerControl().observe(app: app, window: nil, screenshot: screenshot != nil)
                print(look.snapshot.render())
                if let screenshot, let image = look.image { try image.data.write(to: screenshot); print("Screenshot saved to \(screenshot.path)") }
                exit(0)
            } catch {
                print("Error: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
