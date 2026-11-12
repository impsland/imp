#if os(macOS)
// Child processes are macOS-only (the iPhone app shares ImpKit but never runs commands).
import Foundation

/// The environment a new Terminal window would have: what the user's shell sets up in all its
/// startup files, `.zshrc` included.
///
/// An app opened from the Finder or the Dock only gets launchd's bare PATH, and `zsh -l` alone
/// skips `.zshrc`, which is where nvm, fnm, asdf, pyenv and friends put `npx`, `node`, `uvx`…
/// (From a terminal, `open` hands the app that terminal's environment, which is why a build run
/// with `make run` found `npx` and the installed copy didn't.) So, like VS Code, Imp asks the
/// user's shell once, as an interactive login shell, and runs commands with what it prints.
public enum LoginEnvironment {
    /// The process environment with the shell's on top. Asks the shell the first time only; if
    /// the shell fails or hangs, it's the process environment (and the next call asks again).
    public static func resolved() async -> [String: String] {
        await cache.value()
    }

    /// How long the shell may take to start before Imp gives up on it.
    static let timeout: TimeInterval = 10
    static let marker = "__IMP_ENVIRONMENT_7c1f__"
    /// Set per shell, or meaningless for a child: never copied over.
    static let skipped: Set<String> = ["_", "PWD", "OLDPWD", "SHLVL", "TERM_SESSION_ID"]

    private static let cache = Cache()

    private actor Cache {
        private var resolved: [String: String]?
        private var pending: Task<[String: String]?, Never>?

        func value() async -> [String: String] {
            if let resolved { return resolved }
            let task = pending ?? Task.detached(priority: .userInitiated) { LoginEnvironment.ask() }
            pending = task
            let shell = await task.value
            pending = nil
            let base = ProcessInfo.processInfo.environment
            guard let shell else { return base }
            let merged = base.merging(shell) { _, new in new }
            resolved = merged
            return merged
        }
    }

    /// The user's login shell (from the account, else `$SHELL`, else zsh).
    static var shell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell, case let path = String(cString: sh),
           !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let env = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        return "/bin/zsh"
    }

    /// Runs the shell interactively (so it reads `.zshrc`/`.bashrc`) and reads back `env -0`
    /// between markers, so anything a startup file prints is ignored. Nil if it fails or hangs.
    static func ask() -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-i", "-l", "-c", "printf '%s' \(marker); /usr/bin/env -0; printf '%s' \(marker)"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice      // a startup file asking something gets end-of-file
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output

        let collected = Collected()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; done.signal() } else { collected.append(data) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // Something the shell started in the background may hold stdout open: once the markers
        // are both in, that's everything we need.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !collected.isComplete(marker: marker) {
            if done.wait(timeout: .now() + 0.05) == .success { break }
        }
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        return parse(collected.data, marker: marker)
    }

    /// `KEY=value` pairs, NUL-separated, between the first two markers.
    static func parse(_ data: Data, marker: String) -> [String: String]? {
        let m = Data(marker.utf8)
        guard let start = data.range(of: m),
              let end = data.range(of: m, in: start.upperBound..<data.endIndex) else { return nil }
        var env: [String: String] = [:]
        for entry in data[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let line = String(data: Data(entry), encoding: .utf8), let eq = line.firstIndex(of: "="),
                  eq != line.startIndex else { continue }
            let key = String(line[..<eq])
            guard !skipped.contains(key) else { continue }
            env[key] = String(line[line.index(after: eq)...])
        }
        return env["PATH"] == nil ? nil : env
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        var data: Data { lock.withLock { buffer } }
        func append(_ d: Data) { lock.withLock { buffer.append(d) } }
        func isComplete(marker: String) -> Bool {
            let m = Data(marker.utf8)
            return lock.withLock {
                guard let first = buffer.range(of: m) else { return false }
                return buffer.range(of: m, in: first.upperBound..<buffer.endIndex) != nil
            }
        }
    }
}
#endif
