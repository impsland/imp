import Foundation

/// An Imp making another Imp (`imp_create_imp`): the checks and the new profile, apart from the app.
public enum ImpCreation {
    public static let maxNameLength = PocketImp.maxName
    /// The sizes the tool offers, as the Mac's size menu has them.
    public static let sizes: [(name: String, scale: Double)] = [("small", 0.75), ("medium", 1.0), ("large", 1.35)]

    public static var spec: ToolSpec {
        ToolSpec(
            name: OwnTools.createImp,
            description: "Create a new Imp: a helper for a recurring job, or a specialist you can message later with imp_message "
                + "(a reviewer, a researcher, a note taker). It is saved like any Imp and starts with your Brain. Give it a unique `name`, "
                + "a one-line `description` of what it is for (shown in lists and read by other Imps when they choose whom to message), "
                + "and a `system_prompt` with its instructions. Do not create an Imp for a one-off question: ask yourself or message an existing one.",
            inputSchema: ["type": "object",
                          "properties": [
                              "name": ["type": "string", "description": .string("Its name, up to \(maxNameLength) characters, different from every other Imp's.")],
                              "description": ["type": "string", "description": .string("One line: what this Imp is for (up to \(ImpProfile.maxAboutLength) characters).")],
                              "system_prompt": ["type": "string", "description": "Its instructions: who it is and how it works."],
                              "color": ["type": "string", "enum": .array(ImpProfile.colors.map { .string($0.name) }), "description": "Its skin colour."],
                              "size": ["type": "string", "enum": .array(sizes.map { .string($0.name) })],
                          ],
                          "required": ["name"]])
    }
}

extension ImpPreferences {
    /// Adds the Imp the model described, made by Imp `creator`: it has the creator's Brain (shared if the creator's is),
    /// and waits at home like a new Imp until it is let out. Throws a `ToolArgumentError` that says what to fix.
    @discardableResult
    public mutating func createImp(_ args: JSONValue, by creator: UUID) throws -> ImpProfile {
        let name = (args["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolArgumentError("Give the new Imp a `name`.") }
        guard name.count <= ImpCreation.maxNameLength else {
            throw ToolArgumentError("`name` has 1 to \(ImpCreation.maxNameLength) characters.")
        }
        if imps.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ToolArgumentError("An Imp called \(name) exists already. Pick another `name`.")
        }
        var hue: Double?
        if let color = args["color"]?.string?.trimmingCharacters(in: .whitespaces), !color.isEmpty {
            guard let found = ImpProfile.colors.first(where: { $0.name.caseInsensitiveCompare(color) == .orderedSame }) else {
                throw ToolArgumentError("Unknown `color` \(color). Use one of: \(ImpProfile.colors.map(\.name).joined(separator: ", ")).")
            }
            hue = found.hue
        }
        var scale: Double?
        if let size = args["size"]?.string?.trimmingCharacters(in: .whitespaces), !size.isEmpty {
            guard let found = ImpCreation.sizes.first(where: { $0.name == size.lowercased() }) else {
                throw ToolArgumentError("Unknown `size` \(size). Use one of: \(ImpCreation.sizes.map(\.name).joined(separator: ", ")).")
            }
            scale = found.scale
        }
        var profile = ImpProfile.newcomer(joining: imps)
        profile.name = name
        let about = (args["description"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        profile.about = about.isEmpty ? nil : String(about.prefix(ImpProfile.maxAboutLength))
        let prompt = (args["system_prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        profile.personality = prompt.isEmpty ? Persona.newcomer(named: name) : prompt
        if let hue { profile.hue = hue }
        if let scale { profile.scale = scale }
        profile.brain = imps.first { $0.id == creator }?.brain
        profile.isActive = false
        imps.append(profile)
        return profile
    }
}
