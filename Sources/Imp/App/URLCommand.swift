import Foundation

/// `imp://` commands for Shortcuts, Raycast and scripts.
enum URLCommand: CustomStringConvertible {
    case run(action: String, text: String?)   // imp://run?action=Translate%20clipboard[&text=…]
    case ask(String, imp: String?)            // imp://ask?text=…[&imp=Pip]
    case talk                                 // imp://talk
    case type(String, send: Bool)             // imp://type?text=…[&send=1]
    case settings                             // imp://settings

    init?(_ string: String) {
        guard let url = URLComponents(string: string), url.scheme == "imp" else { return nil }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let text = q["text"].flatMap { $0.isEmpty ? nil : $0 }
        switch url.host {
        case "run": guard let name = q["action"] else { return nil }; self = .run(action: name, text: text)
        case "ask": guard let text else { return nil }; self = .ask(text, imp: q["imp"])
        case "talk": self = .talk
        case "type": self = .type(text ?? "", send: q["send"] == "1")
        case "settings": self = .settings
        default: return nil
        }
    }

    var description: String {
        switch self {
        case .run: "run"
        case .ask: "ask"
        case .talk: "talk"
        case .type: "type"
        case .settings: "settings"
        }
    }

    @MainActor func perform(on model: AppModel) {
        switch self {
        case .run(let name, let text): model.run(named: name, text: text)
        case .ask(let text, let imp): model.ask(text, imp: imp)
        case .talk: model.talk()
        case .type(let text, let send): send ? model.submitTyped(text) : model.startTyping(prefill: text)
        case .settings: HomeWindow.shared.show(model)
        }
    }
}
