import Foundation

/// Runs a command with zsh (a login shell with the user's interactive environment, so their PATH applies) in a working folder, with
/// a time limit and a cap on how much output comes back. A failing command isn't an error here:
/// its exit status and output are the result, so the model can read them and try again.
public enum ShellRunner {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
    }

    public static let defaultTimeout: TimeInterval = 120
    /// Output beyond this is cut (models don't need megabytes of logs).
    public static let outputLimit = 16_000

    public static func run(_ command: String, in directory: URL, environment extra: [String: String] = [:],
                           timeout: TimeInterval = defaultTimeout) async throws -> Result {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The user's shell environment (nvm, pyenv… from .zshrc), however Imp was opened.
        var env = await LoginEnvironment.resolved()
        env.merge(extra) { _, new in new }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = env
        process.currentDirectoryURL = directory
        // Nothing to type into: a command waiting for input gets end-of-file instead of hanging.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let collected = Collector(limit: outputLimit)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    collected.timedOut = true
                    process.terminate()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        // Let the last buffered output arrive. Never read to the end: something the command started
        // in the background (`open`, `… &`) may hold the pipe open long after the shell is gone.
        try? await Task.sleep(for: .milliseconds(80))
        output.fileHandleForReading.readabilityHandler = nil

        return Result(status: status, output: collected.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      timedOut: collected.timedOut)
    }

    /// Thread-safe output buffer.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false
        private var _timedOut = false
        let limit: Int

        init(limit: Int) { self.limit = limit }

        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }

        func append(_ chunk: Data) {
            lock.withLock {
                let room = limit - data.count
                guard room > 0 else { truncated = truncated || !chunk.isEmpty; return }
                data.append(chunk.prefix(room))
                if chunk.count > room { truncated = true }
            }
        }

        var text: String {
            lock.withLock { String(decoding: data, as: UTF8.self) + (truncated ? "\n…(output cut)" : "") }
        }
    }
}
