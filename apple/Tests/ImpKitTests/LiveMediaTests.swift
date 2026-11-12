// Live API (opt-in): IMP_LIVE_TESTS=1 swift test --filter LiveMedia
// Makes real pictures and speech through the AI presets' MCP servers (@dtst/img, @dtst/tts) with the
// address, key and models in ./.env (`OPENAI_IMAGE_MODEL`, `OPENAI_SPEECH_MODEL`, and `OPENAI_VOICE` if
// the speech model needs one). Costs a few cents.

import Foundation
import Testing
@testable import ImpKit

/// The image and speech servers as a user sets them up, with the address, key and models from `.env`.
enum LiveMedia {
    static func value(_ name: String) throws -> String {
        try #require(LiveEnv.values?[name].flatMap { $0.isEmpty ? nil : $0 }, "\(name) is not in .env")
    }

    /// A server that starts in `directory`. A Mac app opened from the Finder starts in `/`, so the
    /// servers it runs start there too.
    static func server(_ name: String, package: String, in directory: URL, environment: [String: String]) throws -> MCPServerConfig {
        let live = try LiveEnv.client()
        return MCPServerConfig(name: name, transport: .stdio, command: "/bin/sh",
                               arguments: ["-c", #"cd "$1" && exec npx -y "$2""#, "sh", directory.path, package],
                               environment: ["OPENAI_BASE_URL": live.base, "OPENAI_API_KEY": live.key].merging(environment) { _, new in new })
    }

    static func image(in directory: URL) throws -> MCPServerConfig {
        try server("img", package: "@dtst/img", in: directory, environment: ["OPENAI_MODEL": try value("OPENAI_IMAGE_MODEL")])
    }

    static func speech(in directory: URL) throws -> MCPServerConfig {
        var environment = ["OPENAI_MODEL": try value("OPENAI_SPEECH_MODEL")]
        if let voice = LiveEnv.values?["OPENAI_VOICE"], !voice.isEmpty { environment["OPENAI_VOICE"] = voice }
        return try server("tts", package: "@dtst/tts", in: directory, environment: environment)
    }

    /// A new empty folder for what the servers make.
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imp-live-media-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The local files a tool answer names that exist and are not empty.
    static func files(in answer: String) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: #"(?:file://)?(/[^\s"'`\)\]]+\.[A-Za-z0-9]{2,5})"#)
        let range = NSRange(answer.startIndex..., in: answer)
        let found = pattern.matches(in: answer, range: range).compactMap { match -> URL? in
            guard let r = Range(match.range(at: 1), in: answer) else { return nil }
            let url = URL(fileURLWithPath: String(answer[r]).removingPercentEncoding ?? String(answer[r]))
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0 ? url : nil
        }
        return Array(Set(found))
    }

    /// The files in `folder`, with their sizes.
    static func made(in folder: URL) -> [(name: String, bytes: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().map { name in
            let size = (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (name, size)
        }
    }

    /// Calls `tool` straight on its server, as the hub does.
    static func call(_ config: MCPServerConfig, tool: String, arguments: JSONValue) async throws -> String {
        let client = try MCPClient(config: config)
        try await client.connect()
        let specs = try await client.listTools()
        let spec = try #require(specs.first { $0.name == tool }, "tools: \(specs.map(\.name))")
        print("live media: \(tool) schema \(spec.inputSchema.jsonString)")
        let answer = try await client.callTool(name: tool, arguments: arguments)
        await client.close()
        print("live media: \(tool) answered \(answer.prefix(500).replacingOccurrences(of: "\n", with: " | "))")
        return answer
    }
}

private actor LiveMediaCalls {
    var started: [String] = []
    var finished: [(name: String, ok: Bool, result: String)] = []
    func start(_ name: String) { started.append(name) }
    func finish(_ name: String, _ ok: Bool, _ result: String) { finished.append((name, ok, result)) }
}

@Suite(.enabled(if: LiveEnv.values != nil), .serialized, .timeLimit(.minutes(5))) struct LiveMediaTests {
    @Test func theImageServerMakesAPicture() async throws {
        let folder = try LiveMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let answer = try await LiveMedia.call(try LiveMedia.image(in: folder), tool: "generate_image",
                                              arguments: ["prompt": "A small red apple on a plain white background, simple flat icon."])
        #expect(!answer.hasPrefix("Error"), "\(answer.prefix(400))")
        let made = LiveMedia.made(in: folder)
        print("live media: image files \(made)")
        #expect(made.contains { $0.bytes > 1000 }, "no picture in \(folder.path): \(answer.prefix(400))")
    }

    @Test func theSpeechServerSpeaks() async throws {
        let folder = try LiveMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let answer = try await LiveMedia.call(try LiveMedia.speech(in: folder), tool: "generate_speech",
                                              arguments: ["text": "Hello from Imp."])
        #expect(!answer.hasPrefix("Error"), "\(answer.prefix(400))")
        let made = LiveMedia.made(in: folder)
        print("live media: speech files \(made)")
        #expect(made.contains { $0.bytes > 1000 }, "no sound in \(folder.path): \(answer.prefix(400))")
    }

    /// A Mac app opened from the Finder starts its servers in `/`, where nothing can be written.
    @Test func theImageServerWorksWhenStartedAtTheRoot() async throws {
        let answer = try await LiveMedia.call(try LiveMedia.image(in: URL(fileURLWithPath: "/")), tool: "generate_image",
                                              arguments: ["prompt": "A tiny blue dot on white."])
        let files = LiveMedia.files(in: answer)
        print("live media: files named from the root \(files.map(\.path))")
        // The server picks a new name for each picture, so every file it names was made by this test.
        for file in files { try? FileManager.default.removeItem(at: file) }
        #expect(!answer.hasPrefix("Error"), "\(answer.prefix(400))")
    }

    /// The whole path an Imp takes: the real model, the core's agent loop, the hub offering both
    /// servers' tools under the core's names, and the calls it decides to make.
    @Test func anImpDrawsAndSpeaksWithItsTools() async throws {
        let live = try LiveEnv.client()
        let folder = try LiveMedia.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hub = MCPHub()
        await hub.update([try LiveMedia.image(in: folder), try LiveMedia.speech(in: folder)])
        let offered = await hub.tools().map(\.name)
        print("live media: offered \(offered)")
        #expect(offered.contains { $0.contains("generate_image") } && offered.contains { $0.contains("generate_speech") }, "\(offered)")

        let calls = LiveMediaCalls()
        let agent = Agent(client: live.client, model: live.model, tools: hub, maxSteps: 6)
        let (reply, transcript) = try await agent.run([
            .system("You are Pip, a small desktop helper. Use your tools when asked. Answer in one short sentence."),
            .user("Please draw a tiny green leaf with your picture tool, then say \"Hello from Pip\" aloud with your speech tool."),
        ]) { event in
            switch event {
            case .toolStarted(let name, _): await calls.start(name)
            case .toolFinished(let name, let ok, let result): await calls.finish(name, ok, result)
            default: break
            }
        }
        await hub.update([])

        let started = await calls.started, finished = await calls.finished
        print("live media: tools used \(started)")
        for call in finished { print("live media: \(call.name) ok=\(call.ok) \(call.result.prefix(300).replacingOccurrences(of: "\n", with: " | "))") }
        print("live media: files made \(LiveMedia.made(in: folder))")
        print("live media: reply \(reply.prefix(300))")
        #expect(started.contains { $0.contains("generate_image") }, "used: \(started)")
        #expect(started.contains { $0.contains("generate_speech") }, "used: \(started)")
        let failed = finished.filter { !$0.ok }.map(\.name)
        #expect(failed.isEmpty, "failed: \(failed)")
        #expect(!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(transcript.count > 2)
    }
}
