import Foundation
import Testing
@testable import ImpKit

private let pixel = EncodedImage(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("imp-shell-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct ShellToolTests {
    @Test func offersOneShellToolDescribingItsAPI() async {
        let bare = await ShellTool(directory: scratch()).tools()
        #expect(bare.map(\.name) == [ShellTool.name])
        #expect(!bare[0].description.contains("IMP_API_KEY"), "no API mentioned without one")
        let env = ShellTool.environment(name: "Pip", directory: scratch(), baseURL: "https://openrouter.ai/api/v1",
                                        apiKey: "sk-secret", model: "m")
        let specs = await ShellTool(directory: scratch(), environment: env).tools()
        #expect(specs[0].description.contains("$IMP_API_KEY"))
        #expect(!specs[0].description.contains("sk-secret"), "the key itself never goes into the prompt")
    }

    @Test func environmentSkipsWhatIsMissing() {
        let dir = scratch()
        let env = ShellTool.environment(name: "Pip", directory: dir, baseURL: nil, apiKey: "", model: nil)
        #expect(env == ["IMP_NAME": "Pip", "IMP_WORKSPACE": dir.path])
    }

    @Test func runsInItsFolderWithItsEnvironment() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = ShellTool(directory: dir, environment: ["IMP_NAME": "Pip"])
        let out = try await tool.call(ShellTool.name, arguments: #"{"command": "echo $IMP_NAME; pwd -P"}"#)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "Pip")
        // `pwd -P` spells out the real path (/var is /private/var on macOS).
        #expect(lines.last.map { $0.hasSuffix(dir.lastPathComponent) && dir.path.hasSuffix($0.replacingOccurrences(of: "/private", with: "")) } == true)
    }

    @Test func failuresAreReportedNotThrown() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = ShellTool(directory: dir, timeout: 0.5)
        let failed = try await tool.call(ShellTool.name, arguments: #"{"command": "echo nope >&2; exit 3"}"#)
        #expect(failed.hasPrefix("Error: exit status 3") && failed.contains("nope"))
        let slow = try await tool.call(ShellTool.name, arguments: #"{"command": "sleep 5"}"#)
        #expect(slow.hasPrefix("Error: stopped after"))
        #expect(try await tool.call(ShellTool.name, arguments: "{}").hasPrefix("Error:"))
        #expect(try await tool.call("other", arguments: "{}").hasPrefix("Error:"))
    }

    @Test func doesNotWaitForInputOrBackgroundChildren() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await LoginEnvironment.resolved()          // the one-off shell lookup isn't what's timed here
        let start = Date()
        // `cat` gets end-of-file at once. A background sleep holding the pipe doesn't keep us waiting.
        let r = try await ShellRunner.run("cat; (sleep 3 &); echo done", in: dir, timeout: 10)
        #expect(r.status == 0 && r.output == "done")
        #expect(Date().timeIntervalSince(start) < 2.5)
    }

    @Test func capsLongOutput() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await ShellRunner.run("yes imp | head -n 20000", in: dir)
        #expect(r.output.hasSuffix("…(output cut)"))
        #expect(r.output.count <= ShellRunner.outputLimit + 20)
    }

    @Test func labelsShowTheCommand() {
        let label = ToolLabel(tool: ShellTool.name, arguments: #"{"command": "open -a Safari\nsay hi"}"#)
        #expect(label.title == "open -a Safari…" && label.icon == "terminal")
        #expect(ToolLabel(tool: "files__read_file", arguments: "{}").title == "Files › read file")
    }
}

@Suite struct WorkspaceTests {
    @Test func savesPicturesWithFreshNames() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_000)
        let a = try Workspace.save(pixel, in: dir, at: date)
        let b = try Workspace.save(EncodedImage(data: pixel.data, mimeType: "image/jpeg"), in: dir, at: date)
        let c = try Workspace.save(pixel, in: dir, at: date)
        #expect(a.lastPathComponent == "picture-1000000.png")
        #expect(b.pathExtension == "jpg")
        #expect(c.lastPathComponent == "picture-1000000-2.png")
        #expect(try Data(contentsOf: a) == pixel.data)
        #expect(a.deletingLastPathComponent().lastPathComponent == "attachments")
    }

    @Test func eachImpHasItsOwnFolder() {
        let a = UUID(), b = UUID()
        #expect(Workspace.directory(for: a) != Workspace.directory(for: b))
        #expect(Workspace.directory(for: a).path.contains("Imp/Workspace/\(a.uuidString)"))
    }
}

@Suite struct BriefingTests {
    @Test func shortcutWrapsCopiedTextUnderItsInstruction() {
        let m = Briefing.shortcut("Translate into Chinese.", clip: .text("Hello"))
        #expect(m.role == "user" && m.images == nil)
        #expect(m.content!.hasPrefix("Translate into Chinese.") && m.content!.contains("Hello"))
        // No instruction: the Imp just responds to it.
        #expect(Briefing.shortcut("  ", clip: .text("Hi")).content!.contains("Respond"))
    }

    @Test func picturesAreAttachedAndSavedForCommands() throws {
        let m = Briefing.shortcut("Translate the text in the picture.", clip: .image(pixel), imagePath: "/tmp/picture.png")
        #expect(m.images == [pixel.dataURL])
        #expect(m.content!.contains("/tmp/picture.png"))
        // Sent as multimodal content: the words, then the picture.
        let parts = try #require(m.json["content"] as? [[String: Any]])
        #expect(parts.count == 2 && parts[0]["type"] as? String == "text" && parts[1]["type"] as? String == "image_url")
        // Remembered without the bytes.
        #expect(Briefing.remembered(m).images == nil && Briefing.remembered(m).content == m.content)
        // A pasted picture with no words still asks something.
        #expect(Briefing.message("", image: pixel).content!.contains("picture is attached"))
        #expect(Briefing.message("Hi").json["content"] as? String == "Hi")
    }
}
