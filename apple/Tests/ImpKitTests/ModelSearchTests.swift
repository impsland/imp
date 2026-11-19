import Foundation
import Testing
@testable import ImpKit

/// The model step's search field is separate from the choice: typing never replaces the chosen model.
@MainActor
@Suite("Model search")
struct ModelSearchTests {
    private func flow(models: [String], chosen: String) -> FirstRunModel {
        let services = FirstRunServices(find: { [] }, models: { _, _ in models }, check: { _ in })
        let flow = FirstRunModel(impName: "Dot", target: .existing(UUID()), onThisComputer: false, services: services) { _, _ in }
        flow.models = models
        flow.model = chosen
        return flow
    }

    @Test("An empty search lists every model, the chosen one first")
    func chosenFirst() {
        #expect(flow(models: ["a", "b", "c"], chosen: "b").models(matching: "") == ["b", "a", "c"])
        #expect(flow(models: ["a", "b", "c"], chosen: "").models(matching: "  ") == ["a", "b", "c"])
    }

    @Test("Typing filters the list and leaves the choice alone")
    func typingFilters() {
        let flow = flow(models: ["openai/gpt", "anthropic/claude", "openai/o1"], chosen: "anthropic/claude")
        #expect(flow.models(matching: "OPENAI") == ["openai/gpt", "openai/o1"])
        #expect(flow.model == "anthropic/claude")
        #expect(flow.models(matching: "nothing").isEmpty)
    }
}
