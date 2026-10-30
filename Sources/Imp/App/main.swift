import AppKit
import ImpKit

// Offline renders (used by scripts/build-app.sh and for design review), then exit.
let args = CommandLine.arguments
func argument(after flag: String) -> URL? {
    args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
}
if let url = argument(after: "--render-icon") {
    MainActor.assumeIsolated { IconRenderer.renderIcon(to: url) }
    exit(0)
}
if let url = argument(after: "--render-ios-icon") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        IconRenderer.renderIOSIcon(to: url)
    }
    exit(0)
}
if let url = argument(after: "--render-dmg-background") {
    MainActor.assumeIsolated { IconRenderer.renderDMGBackground(to: url) }
    exit(0)
}
if let url = argument(after: "--render-moods") {
    let cell = args.last.flatMap(Double.init) ?? 160
    MainActor.assumeIsolated { IconRenderer.renderMoods(to: url, cell: cell) }
    exit(0)
}
if let i = args.firstIndex(of: "--render-transition"), args.indices.contains(i + 3),
   let from = Mood.allCases.first(where: { "\($0)" == args[i + 1] }), let to = Mood.allCases.first(where: { "\($0)" == args[i + 2] }) {
    MainActor.assumeIsolated { IconRenderer.renderTransition(from: from, to: to, to: URL(fileURLWithPath: args[i + 3])) }
    exit(0)
}
if let i = args.firstIndex(of: "--render-animation"), args.indices.contains(i + 2),
   let reaction = Reaction(rawValue: args[i + 1]) {
    let preset: String? = args.indices.contains(i + 3) ? args[i + 3] : nil
    let traits: ImpTraits = ImpTraits.presets.first { $0.id == preset }?.traits ?? ImpTraits.plain
    MainActor.assumeIsolated { IconRenderer.renderAnimation(reaction, traits: traits, to: URL(fileURLWithPath: args[i + 2])) }
    exit(0)
}
if let url = argument(after: "--render-turns") {
    let cell = args.last.flatMap(Double.init) ?? 160
    MainActor.assumeIsolated { IconRenderer.renderTurns(to: url, cell: cell) }
    exit(0)
}
if let i = args.firstIndex(of: "--render-home"), args.indices.contains(i + 2) {
    let url = URL(fileURLWithPath: args[i + 2])
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        // Optional review args: imps=N, select=N (Nth Imp), out=N (Nth Imp is on the desktop), away=N (Nth Imp is on an iPhone), hidden=1, width=W, height=H.
        func number(_ key: String) -> Double? { args.first { $0.hasPrefix(key + "=") }.flatMap { Double($0.dropFirst(key.count + 1)) } }
        IconRenderer.renderHome(screen: args[i + 1], to: url,
                                width: number("width").map { CGFloat($0) } ?? 780, height: number("height").map { CGFloat($0) } ?? 600,
                                sampleImps: number("imps").map(Int.init) ?? 1, select: number("select").map(Int.init) ?? 0,
                                out: number("out").map(Int.init), away: number("away").map(Int.init), hidden: number("hidden") == 1)
    }
    exit(0)
}
if let url = argument(after: "--render-kit") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        IconRenderer.renderKit(to: url, entry: args.contains("entry"))
    }
    exit(0)
}
if let url = argument(after: "--render-bubble") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        IconRenderer.renderBubble(to: url, dark: args.contains("dark"))
    }
    exit(0)
}
if let url = argument(after: "--render-exchange") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        IconRenderer.renderExchange(to: url, dark: args.contains("dark"))
    }
    exit(0)
}
if let url = argument(after: "--render-voice") {
    MainActor.assumeIsolated { IconRenderer.renderVoice(to: url, dark: args.contains("dark")) }
    exit(0)
}
if let url = argument(after: "--render-egg") {
    MainActor.assumeIsolated { IconRenderer.renderEgg(to: url) }
    exit(0)
}
if let url = argument(after: "--render-status-icon") {
    MainActor.assumeIsolated { IconRenderer.renderStatusIcon(to: url) }
    exit(0)
}

// Hidden registry check: `Imp --check-kit <file.json>...` reads each file with the real kit parser and prints
// ok / problems / warnings / format version. Exits 1 if any file can't be read or has a problem.
if let i = args.firstIndex(of: "--check-kit") {
    let files = Array(args[(i + 1)...].filter { !$0.hasPrefix("--") })
    exit(KitCheck.run(files: files))
}

// Hidden probe for computer control: `Imp --observe [app] [--screenshot out.png]` prints the element tree.
if let i = args.firstIndex(of: "--observe") {
    let name = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
    MainActor.assumeIsolated { ComputerProbe.run(app: name, screenshot: argument(after: "--screenshot")) }
}

// MCP servers are child processes: a server that exits must not take Imp down with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
