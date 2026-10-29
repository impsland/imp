import ImpKit

/// The computer-control tools (`ComputerTools` names the three) for one Imp, run by its `ComputerControl`.
/// Offered when the Imp has the Computer control group switched on.
struct ComputerToolHost: ToolProvider {
    let control: ComputerControl

    func tools() async -> [ToolSpec] { ComputerTools.specs() }

    func call(_ name: String, arguments: String) async throws -> String {
        try await run(name, arguments: arguments).text
    }

    func run(_ name: String, arguments: String) async throws -> ToolOutput {
        guard ComputerTools.isComputerTool(name) else { throw ToolArgumentError("Unknown tool \(name).") }
        let args = (try? JSONValue(jsonString: arguments.isEmpty ? "{}" : arguments)) ?? [:]
        do {
            switch name {
            case ComputerTools.observe:
                if let problem = await ComputerControl.missingPermission(needsScreen: true) { return ToolOutput(problem) }
                let look = try await control.observe(app: args["app"]?.string, window: args["window"]?.string)
                var text = look.snapshot.render()
                if look.image == nil { text += "\n(No screenshot could be taken.)" }
                return ToolOutput(text, images: look.image.map { [$0] } ?? [])
            case ComputerTools.act:
                let action = try ComputerAction(arguments: args)
                if let problem = await ComputerControl.missingPermission(needsScreen: action.observe) { return ToolOutput(problem) }
                let done = try await control.act(action)
                return ToolOutput(done.text, images: done.image.map { [$0] } ?? [])
            default:
                guard let condition = args["condition"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty else {
                    throw ToolArgumentError("computer_verify needs `condition`: what should be true now.")
                }
                if let problem = await ComputerControl.missingPermission(needsScreen: true) { return ToolOutput(problem) }
                let done = try await control.verify(condition: condition)
                return ToolOutput(done.text, images: done.image.map { [$0] } ?? [])
            }
        } catch let error as ToolArgumentError {
            return ToolOutput("Error: \(error.message)")
        } catch let error as ComputerControl.Failure {
            return ToolOutput("Error: \(error.message)")
        }
    }
}
