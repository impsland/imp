#if os(macOS)
import Foundation
import Testing

/// The design files are generated from `design/tokens.json` and `design/strings`. This fails when
/// someone edits a source and forgets to run `node design/generate.mjs` (or `make tokens`).
@Suite("Generated design files")
struct GeneratedFilesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("Every generated file is current")
    func generatedFilesAreCurrent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", Self.root.appendingPathComponent("design/generate.mjs").path, "--check"]
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(path):/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(text)")
    }
}
#endif
