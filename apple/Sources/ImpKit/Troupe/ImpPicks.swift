import CoreGraphics
import Foundation

/// Several Imps picked at once, to act on them together: hide them, let them out, give them one Brain,
/// a size or a colour, or say goodbye to them in one go.
///
/// On the Mac a ⌘- or ⇧-click adds or removes one, a box drawn on empty space picks the Imps inside it,
/// and Select All picks every one in the window. Fewer than two picked is no group: the menus act on the
/// one Imp they were opened on.
public enum ImpPicks {
    /// The picks after a ⌘-click on `id`. The first such click starts from the Imp chosen so far, so
    /// click, ⌘-click picks two.
    public static func toggle(_ id: UUID, in picked: Set<UUID>, selection: UUID?) -> Set<UUID> {
        var picks = picked.isEmpty ? Set([selection].compactMap { $0 }) : picked
        if picks.contains(id) { picks.remove(id) } else { picks.insert(id) }
        return picks
    }

    /// What a menu opened on `id` acts on: the whole group when `id` is in it, else `id` alone. In the
    /// troupe's order, so lists and dialogs read the same every time.
    public static func group(of id: UUID, picked: Set<UUID>, order: [UUID]) -> [UUID] {
        guard picked.count > 1, picked.contains(id) else { return [id] }
        return order.filter(picked.contains)
    }

    /// The Imps whose middle is inside `box`.
    public static func inside(_ box: CGRect, centres: [UUID: CGPoint]) -> Set<UUID> {
        Set(centres.filter { box.contains($0.value) }.map(\.key))
    }

    /// The box between where a drag started and where it is now, whichever way it goes.
    public static func box(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Whether `count` Imps may go: any of them, all of them too (having no Imp is a calm state).
    public static func canSayGoodbye(to count: Int, of total: Int) -> Bool { count > 0 && count <= total }
}
