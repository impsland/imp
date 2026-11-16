import Foundation
import Testing
import ImpCore
import ImpKit
@testable import Imp

/// Opt-in (IMP_LIVE_TESTS=1, endpoint from `./.env`): two Mac Imps on a real model do the not-waiting flow end to end.
@MainActor @Suite(.enabled(if: TroupeLiveEnv.values != nil), .serialized) struct TroupeLiveTests {
    @Test func pipAsksBoWithoutWaitingAndReadsTheAnswerWhenItWakes() async throws {
        let v = try #require(TroupeLiveEnv.values)
        let app = AppModel(persist: false)
        var service = Service(name: "Live", baseURL: v["OPENAI_BASE_URL"] ?? "", model: v["OPENAI_MODEL"] ?? "")
        service.model = v["OPENAI_MODEL"] ?? ""
        app.prefs.ai.add(service)
        app.assistant.configure(ai: app.prefs.ai, servers: [], keychain: false)
        #expect(app.assistant.setKey(v["OPENAI_API_KEY"] ?? "", for: service.id))
        app.prefs.talkWaiting = .dontWait
        app.prefs.imps[0].name = "Pip"
        app.prefs.imps[0].isActive = true
        let id = app.prefs.addNewcomer()
        let i = app.prefs.imps.firstIndex { $0.id == id }!
        app.prefs.imps[i].name = "Bo"
        app.prefs.imps[i].about = "Knows the capital city of every country."
        app.prefs.imps[i].isActive = true
        for k in app.prefs.imps.indices { app.prefs.imps[k].usesShell = false }
        defer { removeWorkspaces(of: app) }
        let pip = try #require(app.imps.first { $0.profile.name == "Pip" })

        pip.ask("Ask Bo what the capital of Australia is, using imp_message. Don't wait for the answer; tell me you asked. When Bo's answer arrives, tell me the capital.")
        let end = Date().addingTimeInterval(120)
        while Date() < end, !(pip.history.turns.contains { $0.via == .answer && !$0.reply.isEmpty } && !pip.isBusy) {
            try await Task.sleep(for: .milliseconds(200))
        }
        let turns = pip.history.turns
        for t in turns { print("live turn [\(t.via.map(\.rawValue) ?? "-")] request=\(t.request) | steps=\(t.steps.map { "\($0.title) -> \($0.response ?? "")" }) | reply=\(t.reply)") }
        let first = try #require(turns.first)
        let step = try #require(first.steps.first { $0.title.localizedCaseInsensitiveContains("message") || $0.request.contains("Bo") })
        #expect(step.response?.contains("Canberra") == false, "the tool result should be the receipt")
        #expect(step.response == ImpCore.troupeReceipt(to: "Bo", task: Self.task(in: step.response ?? "")))
        let woken = try #require(turns.first { $0.via == .answer })
        #expect(woken.sender?.name == "Bo")
        #expect(woken.reply.localizedCaseInsensitiveContains("Canberra"), "got: \(woken.reply)")
        try await Task.sleep(for: .seconds(1))
    }

    /// The task label inside a receipt: the token that rebuilds exactly this receipt.
    private static func task(in receipt: String) -> String {
        for word in receipt.components(separatedBy: .whitespacesAndNewlines).map({ $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_"))) }) where !word.isEmpty {
            if ImpCore.troupeReceipt(to: "Bo", task: word) == receipt { return word }
        }
        return ""
    }
}

enum TroupeLiveEnv {
    static var values: [String: String]? {
        guard ProcessInfo.processInfo.environment["IMP_LIVE_TESTS"] == "1" else { return nil }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../.env")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        for raw in s.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return out
    }
}
