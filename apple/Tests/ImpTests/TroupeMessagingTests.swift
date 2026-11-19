import Foundation
import Testing
import ImpCore
import ImpKit
@testable import Imp

/// `imp_message` between two Imps of a Mac, with a stub model server behind them: waiting returns the answer in
/// the tool result. Not waiting returns a receipt at once, and the answer comes back as a turn of its own.
@MainActor @Suite(.serialized) struct TroupeMessagingTests {
    private struct World {
        let app: AppModel
        let pip: ImpModel
        let bo: ImpModel
    }

    private func world(_ server: StubModelServer, waiting: TalkWaiting, extra: [String] = []) -> World {
        let app = AppModel(persist: false)
        app.prefs.imps = [.waiting]
        var service = Service(name: "Stub", baseURL: server.baseURL, model: "stub")
        service.model = "stub"
        app.prefs.ai.add(service)
        app.assistant.configure(ai: app.prefs.ai, servers: [], keychain: false)
        app.prefs.talkWaiting = waiting
        // Pip is a newcomer too, not the first Imp: that one has the fixed default id, which other suites' apps
        // use at the same time, and its folder is the person's own.
        app.prefs.imps[0].isActive = false
        for name in ["Pip", "Bo"] + extra {
            let id = app.prefs.addNewcomer()
            let i = app.prefs.imps.firstIndex { $0.id == id }!
            app.prefs.imps[i].name = name
            app.prefs.imps[i].personality = "You are \(name)."
            if name != "Pip" { app.prefs.imps[i].about = "\(name) knows capital cities." }
            app.prefs.imps[i].isActive = true
        }
        for i in app.prefs.imps.indices { app.prefs.imps[i].usesShell = false }
        let pip = app.imps.first { $0.profile.name == "Pip" }!, bo = app.imps.first { $0.profile.name == "Bo" }!
        return World(app: app, pip: pip, bo: bo)
    }

    /// Waits for `done`, polling. The limit only bounds a failure: every suite in this target shares the main actor,
    /// and while others render there a turn can wait its turn for seconds.
    private func until(_ seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Lets the answers still on their way land, so nothing outlives the test's model.
    private func drain(_ w: World) async {
        await until { w.app.pendingMessages.isEmpty && !w.pip.isBusy && !w.bo.isBusy }
        try? await Task.sleep(for: .milliseconds(300))
        await until { !w.pip.isBusy && !w.bo.isBusy }
        removeWorkspaces(of: w.app)
    }

    private func sendArguments(to: String, wait: Bool? = nil) -> String {
        let w = wait.map { #","wait":\#($0)"# } ?? ""
        return #"{"to":"\#(to)","text":"What is the capital of Australia?"\#(w)}"#
    }

    private func isPip(_ r: StubModelServer.Request) -> Bool { r.system.contains("You are Pip.") }

    // MARK: Not waiting

    @Test func notWaitingReturnsAReceiptAndTheAnswerWakesTheSender() async throws {
        let server = try StubModelServer { r in
            if !(r.system.contains("You are Pip.")) { return .text("Canberra.", delay: 0.8) }      // Bo
            switch r.last.role {
            case "tool": return .text("I asked Bo.")
            case "user" where r.last.content.contains("Canberra"): return .text("Bo says Canberra.")
            default: return .calls([(OwnTools.message, #"{"to":"Bo","text":"What is the capital of Australia?","wait":false}"#)])
            }
        }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .decides)
        w.pip.ask("Ask Bo for the capital of Australia.")

        await until { w.pip.history.turns.contains { $0.via == .answer } && !w.pip.isBusy }
        let turns = w.pip.history.turns
        let first = try #require(turns.first)
        let receiptStep = try #require(first.steps.first)
        // The receipt came back at once: Bo's answer was still 0.8 s away when Pip finished its first turn.
        #expect(receiptStep.response?.contains("Bo") == true)
        #expect(receiptStep.response?.contains("Canberra") == false)
        #expect(first.reply == "I asked Bo.")

        let woken = try #require(turns.first { $0.via == .answer })
        #expect(woken.sender?.name == "Bo")
        #expect(woken.request == "Canberra.")
        #expect(woken.reply == "Bo says Canberra.")
        #expect(turns.firstIndex { $0.id == woken.id }! > 0)
        // The earlier tool result is never edited.
        #expect(w.pip.history.turns[0].steps.first?.response == receiptStep.response)

        #expect(w.app.pendingMessages[w.pip.id] == nil)
    }

    @Test func theWokenTurnReceivesTheAnswerEventAfterTheReceipt() async throws {
        let seen = Seen()
        let server = try StubModelServer { r in
            if !r.system.contains("You are Pip.") { return .text("Canberra.", delay: 0.4) }
            seen.add(r)
            switch r.last.role {
            case "tool": return .text("I asked Bo.")
            case "user" where r.last.content.contains("Canberra"): return .text("Bo says Canberra.")
            default: return .calls([(OwnTools.message, #"{"to":"Bo","text":"What is the capital of Australia?","wait":false}"#)])
            }
        }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .dontWait)
        w.pip.ask("Ask Bo for the capital of Australia.")
        await until { w.pip.history.turns.contains { $0.via == .answer } && !w.pip.isBusy }

        let requests = seen.all
        let afterTool = try #require(requests.first { $0.last.role == "tool" })
        let woken = try #require(requests.last)
        #expect(woken.last.role == "user")
        let receipt = afterTool.last.content
        #expect(receipt.contains("Bo"))
        // The user message is the core's answer event for this very message (its task label is in the receipt).
        let task = try #require(Self.taskLabel(in: woken.last.content, receipt: receipt))
        let expected = ImpCore.troupeAnswerEvent(from: "Bo", task: task, sent: Self.sent(in: woken.last.content), text: "Canberra.", failed: false)
        #expect(woken.last.content == expected)
        #expect(woken.messages.contains { $0.role == "tool" && $0.content == receipt })
        #expect(woken.messages.filter { $0.role == "tool" }.allSatisfy { !$0.content.contains("Canberra") })
    }

    /// The task label the receipt was made with: the part of the answer event that also stands in the receipt.
    private static func taskLabel(in event: String, receipt: String) -> String? {
        for word in receipt.components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_"))) where word.count > 2 && event.contains(word) {
            if ImpCore.troupeReceipt(to: "Bo", task: word) == receipt { return word }
        }
        return nil
    }
    private static func sent(in event: String) -> String {
        event.range(of: #"\d{2}:\d{2}"#, options: .regularExpression).map { String(event[$0]) } ?? ""
    }

    // MARK: Busy sender

    @Test func answersThatArriveMidTurnWaitForTheTurnToEndInOrder() async throws {
        let seen = Seen()
        let server = try StubModelServer { r in
            if !r.system.contains("You are Pip.") {
                return .text(r.system.contains("You are Bo.") ? "Bo answer." : "Cy answer.", delay: r.system.contains("You are Bo.") ? 0.1 : 0.3)
            }
            seen.add(r)
            switch r.last.role {
            case "tool": return .text("Pip first turn done.", delay: 1.2)             // the turn is still running when both answers are in
            case "user" where r.last.content.contains("answer."): return .text("Pip read it.")
            default:
                return .calls([(OwnTools.message, #"{"to":"Bo","text":"Hi Bo","wait":false}"#),
                               (OwnTools.message, #"{"to":"Cy","text":"Hi Cy","wait":false}"#)])
            }
        }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .dontWait, extra: ["Cy"])
        w.pip.ask("Say hi to Bo and Cy.")
        await until { w.pip.history.turns.filter { $0.via == .answer }.count == 2 && !w.pip.isBusy }

        let turns = w.pip.history.turns
        #expect(turns.first?.reply == "Pip first turn done.")
        #expect(turns.compactMap(\.sender?.name) == ["Bo", "Cy"])
        #expect(turns.map(\.via) == [.typed, .answer, .answer])
        // The first answer's turn did not start before the first turn ended: its request is the only one with the event.
        let events = seen.all.filter { $0.last.role == "user" && $0.last.content.contains("answer.") }
        #expect(events.count == 2)
        #expect(events[0].last.content.contains("Bo answer."))
        #expect(events[1].last.content.contains("Cy answer."))
        let toolsAnswered = seen.all.firstIndex { $0.last.role == "tool" }!
        #expect(seen.all.firstIndex { $0.last.role == "user" && $0.last.content.contains("answer.") }! > toolsAnswered)
    }

    // MARK: Limits

    @Test func aFifthPendingMessageIsRefusedWithTheCoresSentence() async throws {
        let server = try StubModelServer { _ in .text("ok") }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .dontWait)
        let host = OwnToolHost(app: w.app, imp: w.pip.id, messaging: true)
        let limit: String? = ImpCore.troupeMayLeave(pending: 4, depth: 0)
        let refusal = try #require(limit)
        w.app.pendingMessages[w.pip.id] = 3
        let fourth = try await host.call(OwnTools.message, arguments: sendArguments(to: "Bo"))
        #expect(fourth.contains("Bo"))
        #expect(w.app.pendingMessages[w.pip.id] == 4)
        let fifth = try await host.call(OwnTools.message, arguments: sendArguments(to: "Bo"))
        #expect(fifth == "Error: " + refusal)
        #expect(w.app.pendingMessages[w.pip.id] == 4)
        w.app.pendingMessages[w.pip.id] = 1                  // the three made-up ones are gone. The real one is on its way
        await drain(w)
    }

    @Test func aSendFromATurnWokenAtMaxDepthIsRefused() async throws {
        let server = try StubModelServer { _ in .text("ok") }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .dontWait)
        var maxDepth = 0
        while ImpCore.troupeMayLeave(pending: 0, depth: UInt32(maxDepth)) == nil { maxDepth += 1 }
        #expect(maxDepth == 3)
        let ok = OwnToolHost(app: w.app, imp: w.pip.id, messaging: true, depth: maxDepth - 1)
        _ = try await ok.call(OwnTools.message, arguments: sendArguments(to: "Bo"))
        let host = OwnToolHost(app: w.app, imp: w.pip.id, messaging: true, depth: maxDepth)
        let refusal: String? = ImpCore.troupeMayLeave(pending: 0, depth: UInt32(maxDepth))
        let refused = try await host.call(OwnTools.message, arguments: sendArguments(to: "Bo"))
        #expect(refused == "Error: " + (refusal ?? "?"))
        #expect(w.app.pendingMessages[w.pip.id] == 1)
        await drain(w)
    }

    /// End to end: every woken turn sends again. The chain stops by itself at the depth limit.
    @Test func aChainOfWokenTurnsStopsAtTheDepthLimit() async throws {
        let server = try StubModelServer { r in
            if !r.system.contains("You are Pip.") { return .text("Bo here.") }
            switch r.last.role {
            case "tool": return .text(r.last.content.contains("Bo") && !r.last.content.hasPrefix("Error") ? "Sent." : "Refused: \(r.last.content)")
            default: return .calls([(OwnTools.message, #"{"to":"Bo","text":"again","wait":false}"#)])
            }
        }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .dontWait)
        w.pip.ask("Start.")
        await until { w.pip.history.turns.contains { $0.reply.hasPrefix("Refused") } && !w.pip.isBusy }
        await drain(w)
        let turns = w.pip.history.turns
        // The user's turn (depth 0) and three woken turns (depth 1 to 3): the last one's send is refused.
        #expect(turns.map(\.via) == [.typed, .answer, .answer, .answer])
        let refusal: String? = ImpCore.troupeMayLeave(pending: 0, depth: 3)
        #expect(turns.last?.reply.contains(refusal ?? "?") == true)
    }

    // MARK: Waiting

    @Test func waitingStillReturnsTheAnswerInTheToolResult() async throws {
        let server = try StubModelServer { r in
            if !r.system.contains("You are Pip.") { return .text("Canberra.") }
            if r.last.role == "tool" { return .text("Done.") }
            return .calls([(OwnTools.message, #"{"to":"Bo","text":"Capital of Australia?"}"#)])
        }
        try await server.start(); defer { server.stop() }
        for (setting, wait) in [(TalkWaiting.wait, ""), (.decides, #","wait":true"#)] {
            let w = world(server, waiting: setting)
            let host = OwnToolHost(app: w.app, imp: w.pip.id, messaging: true)
            let out = try await host.call(OwnTools.message, arguments: #"{"to":"Bo","text":"Capital of Australia?"\#(wait)}"#)
            #expect(out == "Bo says: Canberra.")
            #expect(w.app.pendingMessages[w.pip.id] == nil)
            #expect(!w.pip.history.turns.contains { $0.via == .answer })
        }
    }

    @Test func decidesWithWaitFalseDoesNotWait() async throws {
        let server = try StubModelServer { _ in .text("Canberra.", delay: 0.5) }
        try await server.start(); defer { server.stop() }
        let w = world(server, waiting: .decides)
        let host = OwnToolHost(app: w.app, imp: w.pip.id, messaging: true)
        let started = Date()
        let out = try await host.call(OwnTools.message, arguments: sendArguments(to: "Bo", wait: false))
        #expect(Date().timeIntervalSince(started) < 0.4)
        #expect(out.contains("Bo") && !out.contains("Canberra"))
        #expect(w.app.pendingMessages[w.pip.id] == 1)
        await until { w.pip.history.turns.contains { $0.via == .answer } && !w.pip.isBusy }
        #expect(w.pip.history.turns.first { $0.via == .answer }?.request == "Canberra.")
        #expect(w.app.pendingMessages[w.pip.id] == nil)
    }

    // MARK: Profiles

    @Test func theToolDescriptionListsWhatEachImpSaysAboutItself() {
        let app = AppModel(persist: false)
        app.prefs.imps = [.waiting]
        app.prefs.imps[0].name = "Pip"
        app.prefs.imps[0].isActive = true
        let id = app.prefs.addNewcomer()
        let i = app.prefs.imps.firstIndex { $0.id == id }!
        app.prefs.imps[i].name = "Bo"
        app.prefs.imps[i].about = "Knows every capital city."
        app.prefs.imps[i].isActive = true
        let pip = app.imps.first { $0.profile.name == "Pip" }!
        let specs = OwnToolHost(app: app, imp: pip.id, messaging: true).specs()
        let tool = specs.first { $0.name == OwnTools.message }
        #expect(tool?.description.contains("Bo") == true)
        #expect(tool?.description.contains("Knows every capital city.") == true)
        removeWorkspaces(of: app)
    }
}

/// Removes the folders the test's Imps got in Application Support. Never the first Imp's: it has the fixed
/// default id, so its folder is the person's own first Imp's.
@MainActor func removeWorkspaces(of app: AppModel) {
    for profile in app.prefs.imps where profile.id != ImpProfile.defaultID {
        try? FileManager.default.removeItem(at: Workspace.directory(for: profile.id))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [StubModelServer.Request] = []
    func add(_ r: StubModelServer.Request) { lock.withLock { requests.append(r) } }
    var all: [StubModelServer.Request] { lock.withLock { requests } }
}
