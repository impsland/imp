import Foundation

/// Where an Imp's questions wait for the person: one is asked at a time, a second one while the first is
/// still open queues behind it. The answer resumes the call that asked; stopping the work (the asking task is
/// cancelled) answers Deny. The bubble shows `current`, and `onChange` tells it when that changes.
@MainActor
public final class PermissionDesk: PermissionAsking {
    private struct Pending {
        let id: UUID
        let question: PermissionQuestion
        let continuation: CheckedContinuation<PermissionAnswer, Never>
    }

    private var queue: [Pending] = []

    /// Called whenever `current` changes.
    public var onChange: () -> Void = {}

    public nonisolated init() {}

    /// The question the person is asked now (nil when none waits).
    public var current: PermissionQuestion? { queue.first?.question }

    /// How many questions wait, the open one included.
    public var count: Int { queue.count }

    public nonisolated func ask(_ question: PermissionQuestion) async -> PermissionAnswer {
        let id = UUID()
        return await withTaskCancellationHandler {
            await park(question, id: id)
        } onCancel: {
            Task { @MainActor in self.settle(id: id, with: .deny) }
        }
    }

    private func park(_ question: PermissionQuestion, id: UUID) async -> PermissionAnswer {
        await withCheckedContinuation { continuation in
            // Cancelled before it was parked: nothing would ever answer.
            if Task.isCancelled { continuation.resume(returning: .deny); return }
            queue.append(Pending(id: id, question: question, continuation: continuation))
            if queue.count == 1 { onChange() }
        }
    }

    /// The person's answer to the open question.
    public func answer(_ answer: PermissionAnswer) {
        guard let first = queue.first else { return }
        settle(id: first.id, with: answer)
    }

    /// Denies every question (the Imp stopped, or the person closed everything).
    public func denyAll() {
        while let first = queue.first { settle(id: first.id, with: .deny) }
    }

    private func settle(id: UUID, with answer: PermissionAnswer) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let was = i == 0
        let pending = queue.remove(at: i)
        pending.continuation.resume(returning: answer)
        if was { onChange() }
    }
}
