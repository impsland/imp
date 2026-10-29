import CoreGraphics
import Foundation

/// How the three coordinate systems of computer control relate. This is the one place that says so.
///
/// - Accessibility (AX) positions and CGEvent mouse locations are both in *global points*, origin
///   at the top-left of the primary display, y growing down. `SCWindow.frame` is in the same space.
/// - The screenshot of a window is `windowFrame.size * scale` pixels. `scale` is 1 for windows up
///   to `maxLongSide` points on the long side and smaller for bigger ones, so the image stays cheap.
///   (Retina pixels are not used: the image is sized in points, not device pixels.)
/// - Everything the model reads and sends is in *image pixels*, origin at the image's top-left:
///   `image = (global - windowFrame.origin) * scale`, and back: `global = image / scale + origin`.
public struct ComputerSpace: Equatable, Sendable {
    public static let maxLongSide: CGFloat = 1280

    /// The window, in global points.
    public var windowFrame: CGRect
    public var scale: CGFloat

    public init(windowFrame: CGRect, maxLongSide: CGFloat = ComputerSpace.maxLongSide) {
        self.windowFrame = windowFrame
        let long = max(windowFrame.width, windowFrame.height)
        scale = long > maxLongSide ? maxLongSide / long : 1
    }

    /// Size of the screenshot, in pixels.
    public var imageSize: CGSize {
        CGSize(width: max(1, (windowFrame.width * scale).rounded()), height: max(1, (windowFrame.height * scale).rounded()))
    }

    public func image(fromGlobal p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - windowFrame.minX) * scale, y: (p.y - windowFrame.minY) * scale)
    }

    public func global(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / scale + windowFrame.minX, y: p.y / scale + windowFrame.minY)
    }

    public func image(fromGlobal r: CGRect) -> CGRect {
        CGRect(origin: image(fromGlobal: r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
    }

    /// Inside the screenshot (a click outside the window is refused).
    public func containsImage(_ p: CGPoint) -> Bool {
        CGRect(origin: .zero, size: imageSize).contains(p)
    }
}

/// Short stable ids ("e12") for elements: the same element (same path of roles and names from the
/// window) keeps its id from one observation to the next, so changes can be told and ids stay valid.
public struct ComputerElementIDs: Sendable {
    private var known: [String: String] = [:]
    private var next = 1
    public init() {}

    public mutating func id(for key: String) -> String {
        if let id = known[key] { return id }
        defer { next += 1 }
        let id = "e\(next)"
        known[key] = id
        return id
    }
}

/// One accessible element, with its frame in screenshot pixels.
public struct ComputerElement: Equatable, Sendable {
    public var id: String
    public var role: String
    public var name: String
    public var value: String
    public var enabled = true
    public var focused = false
    public var frame: CGRect
    public var depth = 0

    public init(id: String, role: String, name: String = "", value: String = "", enabled: Bool = true,
                focused: Bool = false, frame: CGRect, depth: Int = 0) {
        self.id = id; self.role = role; self.name = name; self.value = value
        self.enabled = enabled; self.focused = focused; self.frame = frame; self.depth = depth
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    static func clip(_ s: String, _ n: Int = 80) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }

    /// `e12 button "Save" value="x" disabled focused @10,20 80x24`
    public var line: String {
        var s = "\(id) \(role)"
        if !name.isEmpty { s += " “\(Self.clip(name))”" }
        if !value.isEmpty { s += " value=“\(Self.clip(value))”" }
        if !enabled { s += " disabled" }
        if focused { s += " focused" }
        return s + " @\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }
}

/// A window of the app, for choosing.
public struct ComputerWindow: Equatable, Sendable {
    public var title: String
    public var isTarget: Bool
    public init(title: String, isTarget: Bool) { self.title = title; self.isTarget = isTarget }
}

/// What an observation found: the window, its elements, and the means to describe and compare it.
public struct ComputerSnapshot: Equatable, Sendable {
    public var app: String
    public var windowTitle: String
    /// Same app and window as another snapshot (diffs only make sense then).
    public var windowKey: String
    public var windows: [ComputerWindow]
    public var imageSize: CGSize
    public var elements: [ComputerElement]
    /// Elements left out by the caps.
    public var omitted = 0
    /// Top-level menus of the app's menu bar.
    public var menus: [String] = []

    public init(app: String, windowTitle: String, windowKey: String, windows: [ComputerWindow] = [], imageSize: CGSize,
                elements: [ComputerElement], omitted: Int = 0, menus: [String] = []) {
        self.app = app; self.windowTitle = windowTitle; self.windowKey = windowKey; self.windows = windows
        self.imageSize = imageSize; self.elements = elements; self.omitted = omitted; self.menus = menus
    }

    /// Fewer meaningful elements than this and the model is told to work from the picture.
    public static let sparse = 6

    public func element(_ id: String) -> ComputerElement? { elements.first { $0.id == id } }

    /// Elements whose name or value is `text` (exact matches first, then starts-with, then contains).
    public func find(_ text: String) -> [ComputerElement] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func rank(_ e: ComputerElement) -> Int? {
            let n = e.name.lowercased(), v = e.value.lowercased()
            if n == q { return 0 }
            if v == q { return 1 }
            if n.hasPrefix(q) { return 2 }
            if n.contains(q) { return 3 }
            if v.contains(q) { return 4 }
            return nil
        }
        return elements.compactMap { e in rank(e).map { (e, $0) } }
            .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }

    /// The text of an observation (the screenshot travels beside it).
    public func render() -> String {
        var out = ["App: \(app). Window: “\(windowTitle)”."]
        if windows.count > 1 {
            out.append("Windows: " + windows.enumerated().map { "\($0.offset + 1). “\($0.element.title)”\($0.element.isTarget ? " (this one)" : "")" }
                .joined(separator: ", ") + ". Pass `window` to look at another.")
        }
        if !menus.isEmpty { out.append("Menu bar: \(menus.joined(separator: ", ")). Use computer_act select with a path like \"\(menus[min(1, menus.count - 1)]) > …\".") }
        out.append("Screenshot: \(Int(imageSize.width))x\(Int(imageSize.height)) px. All coordinates are in screenshot pixels from the top-left corner (x right, y down).")
        if elements.count < Self.sparse {
            out.append("This window exposes little through accessibility (\(elements.count) elements): work from the screenshot and act with `x`,`y` coordinates.")
        }
        if !elements.isEmpty {
            out.append("Elements (indented = inside the one above" + (omitted > 0 ? "; \(omitted) more not shown, ask for a smaller window or use coordinates" : "") + "):")
            out += elements.map { String(repeating: "  ", count: $0.depth) + $0.line }
        }
        return out.joined(separator: "\n")
    }

    /// What changed from `old` to this, in a few lines. Nil when it's another window.
    public func changes(since old: ComputerSnapshot, limit: Int = 30) -> String? {
        guard old.windowKey == windowKey else { return nil }
        let before = Dictionary(old.elements.map { ($0.id, $0) }) { a, _ in a }
        let after = Dictionary(elements.map { ($0.id, $0) }) { a, _ in a }
        var added: [String] = [], changed: [String] = [], removed: [String] = []
        for e in elements {
            guard let o = before[e.id] else { added.append("+ " + e.line); continue }
            var what: [String] = []
            if o.name != e.name { what.append("name “\(ComputerElement.clip(o.name, 40))” → “\(ComputerElement.clip(e.name, 40))”") }
            if o.value != e.value { what.append("value “\(ComputerElement.clip(o.value, 40))” → “\(ComputerElement.clip(e.value, 40))”") }
            if o.enabled != e.enabled { what.append(e.enabled ? "now enabled" : "now disabled") }
            if o.focused != e.focused { what.append(e.focused ? "now focused" : "lost focus") }
            if !what.isEmpty { changed.append("~ \(e.id) \(e.role)\(e.name.isEmpty ? "" : " “\(ComputerElement.clip(e.name, 40))”"): " + what.joined(separator: ", ")) }
        }
        for o in old.elements where after[o.id] == nil {
            removed.append("- \(o.id) \(o.role)\(o.name.isEmpty ? "" : " “\(ComputerElement.clip(o.name, 40))”")")
        }
        let lines = added + changed + removed
        if lines.isEmpty { return "No change in the elements." }
        var out = Array(lines.prefix(limit))
        if lines.count > limit { out.append("…and \(lines.count - limit) more changes") }
        return out.joined(separator: "\n")
    }
}
