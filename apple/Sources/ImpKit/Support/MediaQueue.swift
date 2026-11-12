/// Which of a reply's players starts next. Players the Imp marked `#autoplay` in one answer play
/// one after another, in the order they're written, not over each other: one that turns up while
/// another of the same answer is still going waits its turn. A newer answer takes over, and so does
/// you starting something yourself somewhere else.
public struct MediaQueue<ID: Hashable> {
    /// A player: what it is, which answer it's in, and where in that answer (0 is the first).
    public struct Item: Equatable {
        public var id: ID
        public var owner: String
        public var order: Int
        public init(id: ID, owner: String, order: Int) { self.id = id; self.owner = owner; self.order = order }
    }

    /// The answer whose players are taking turns.
    public private(set) var owner: String?
    /// Waiting their turn, first in the answer first.
    public private(set) var waiting: [Item] = []

    public init() {}

    /// `item` asks to start on its own. `busy` is what's playing now (or stopped halfway through):
    /// true means start it now, false means it waits.
    public mutating func autoplay(_ item: Item, busy: Item?) -> Bool {
        guard owner == item.owner else {
            owner = item.owner                       // a newer answer: the old one's turns are over
            waiting = []
            return true
        }
        let behind = busy.map { $0.owner == item.owner && $0.id != item.id } ?? false
        guard behind else {
            waiting.removeAll { $0.id == item.id }
            return true
        }
        if !waiting.contains(where: { $0.id == item.id }) {
            waiting.append(item)
            waiting.sort { $0.order < $1.order }
        }
        return false
    }

    /// `item` played to its end (or couldn't play): the next one waiting after it, if any, goes now.
    public mutating func finished(_ item: Item) -> Item? {
        guard item.owner == owner else { return nil }
        return next(after: item.order)
    }

    /// You started `item` yourself: in another answer, that answer's turns are over.
    public mutating func started(_ item: Item?) {
        guard item?.owner != owner else {
            if let item { waiting.removeAll { $0.id == item.id } }
            return
        }
        owner = nil
        waiting = []
    }

    /// The player is gone (its view closed): it no longer waits.
    public mutating func remove(_ id: ID) {
        waiting.removeAll { $0.id == id }
    }

    /// Takes the first one waiting after `order` (skipping, for good, any before it).
    private mutating func next(after order: Int?) -> Item? {
        if let order { waiting.removeAll { $0.order <= order } }
        return waiting.isEmpty ? nil : waiting.removeFirst()
    }
}
