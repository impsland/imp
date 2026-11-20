import ImpDesign
import ImpKit
import SwiftUI

extension View {
    /// Asks before saying goodbye to the Imps in `ids` (nil asks nothing), by `names`. `say` runs when the user
    /// confirms. The window, an Imp's menu, an Imp's settings and the iPhone app all ask this same question.
    func goodbyeQuestion(_ ids: Binding<[UUID]?>, names: [String], say: @escaping ([UUID]) -> Void) -> some View {
        modifier(GoodbyeQuestion(ids: ids, names: names, say: say))
    }
}

/// One Imp is asked about by name. Several Imps picked together are asked about once, for all of them.
/// Keeping them is the default answer, so pressing Return keeps them.
private struct GoodbyeQuestion: ViewModifier {
    @Binding var ids: [UUID]?
    let names: [String]
    let say: ([UUID]) -> Void

    private var isOne: Bool { ids?.count == 1 }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { ids != nil }, set: { if !$0 { ids = nil } }),
                                   titleVisibility: .visible) {
            Button(role: .destructive) {
                if let chosen = ids { say(chosen) }
            } label: {
                Text("goodbye.confirm")
            }
            Button(role: .cancel) { ids = nil } label: { Text(keep) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(verbatim: message)
        }
    }

    private var title: String {
        isOne ? words("goodbye.title", names.first ?? "") : words("goodbye.many.title", ids?.count ?? 0)
    }

    private var keep: String {
        isOne ? words("goodbye.cancel", names.first ?? "") : String(localized: "goodbye.many.cancel")
    }

    private var message: String {
        isOne ? String(localized: "goodbye.message")
            : names.formatted(.list(type: .and)) + "\n\n" + String(localized: "goodbye.many.message")
    }
}
