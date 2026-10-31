import Foundation

/// Who can message whom, and where a `message` goes (see "Imps talking" in `docs/LINK.md`). An Imp
/// can message the other Imps of its home and the Imps on the screen its body is on. The home sends
/// the question to the device that can answer: the target's home, or the holder of the asking Imp,
/// which answers for its own Imps and forwards once to the target's home. The answer goes back the
/// same way. Pure.
public enum LinkTalks {
    /// The Imps `asker` can message from where its body is. `mine` are the Imps of its home (this
    /// device), `stage` the Imps on the screen where its body is.
    public static func targets(of asker: UUID, mine: [LinkStaged], stage: [LinkStaged]) -> [LinkStaged] {
        var seen = Set<UUID>([asker])
        return (mine + stage).filter { seen.insert($0.id).inserted }
    }

    public enum First: Sendable, Equatable {
        /// The target's home is this device: answer here.
        case here
        /// Send it to this device.
        case via(UUID)
        /// Nobody connected can answer.
        case unreachable
    }

    /// Where a question from an Imp of this device (`me` is its home) goes first. `holder` is the
    /// device the asking Imp's body is on (`me` when it is at home).
    public static func first(me: UUID, targetHome: UUID, holder: UUID, connected: Set<UUID>) -> First {
        if targetHome == me { return .here }
        if connected.contains(targetHome) { return .via(targetHome) }
        if holder != me, connected.contains(holder) { return .via(holder) }
        return .unreachable
    }

    public enum Received: Sendable, Equatable {
        /// The target's home is this device: answer it.
        case answer
        /// Not for this device: pass it on (once) to the target's home.
        case forward(to: UUID)
        /// Can't be answered or forwarded from here.
        case refuse
    }

    /// What a device does with a `message` that came from `sender`.
    public static func received(me: UUID, targetHome: UUID, forwarded: Bool, sender: UUID, connected: Set<UUID>) -> Received {
        if targetHome == me { return .answer }
        if !forwarded, targetHome != sender, connected.contains(targetHome) { return .forward(to: targetHome) }
        return .refuse
    }

    /// Whether a question for an Imp of this device may be answered: its asker must be on the screen the
    /// target's body is on (`screen`: our own stage if the target is here, the holder's stage if it is
    /// away). A forwarded one must also come from a device whose stage (`senderStage`) holds the asker,
    /// or which is the asker's home according to some stage we know (`known`).
    public static func mayAsk(asker: UUID, screen: [LinkStaged], forwarded: Bool, sender: UUID,
                              senderStage: [LinkStaged], known: [LinkStaged]) -> Bool {
        guard screen.contains(where: { $0.id == asker }) else { return false }
        guard forwarded else { return true }
        return senderStage.contains { $0.id == asker } || known.contains { $0.id == asker && $0.home == sender }
    }

    /// How many questions one device may have in flight through this one.
    public static let perSender = 16

    /// Questions in flight, so each answer finds its way back, and a question nobody answers fails.
    public struct Pending: Sendable {
        public struct Question: Sendable, Equatable {
            public var id: UUID
            /// The device that sent it here (nil: asked from this device).
            public var from: UUID?
            /// The device it went on to.
            public var to: UUID
            var deadline: Date
        }

        public private(set) var questions: [UUID: Question] = [:]

        public init() {}

        /// False if a question with this id is in flight already (it is not replaced).
        @discardableResult
        public mutating func sent(_ id: UUID, from: UUID?, to: UUID, now: Date = Date(), timeout: TimeInterval = LinkProtocol.answerTimeout) -> Bool {
            guard questions[id] == nil else { return false }
            questions[id] = Question(id: id, from: from, to: to, deadline: now.addingTimeInterval(timeout))
            return true
        }

        /// How many questions `device` has in flight through here.
        public func count(from device: UUID) -> Int { questions.values.filter { $0.from == device }.count }

        /// An answer came from `device`. Nil unless it is the one the question went to.
        public mutating func answered(_ id: UUID, by device: UUID) -> Question? {
            guard let q = questions[id], q.to == device else { return nil }
            questions[id] = nil
            return q
        }

        /// The questions that ran out of time.
        public mutating func expired(now: Date = Date()) -> [Question] {
            let late = questions.values.filter { $0.deadline <= now }
            late.forEach { questions[$0.id] = nil }
            return late
        }

        /// The questions that went to `device`, which just went away.
        public mutating func lost(_ device: UUID) -> [Question] {
            let gone = questions.values.filter { $0.to == device }
            gone.forEach { questions[$0.id] = nil }
            return gone
        }
    }
}
