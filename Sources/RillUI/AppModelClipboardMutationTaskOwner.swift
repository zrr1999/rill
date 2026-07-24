import Foundation

/// Owns every clipboard mutation launched by `AppModel` so application
/// shutdown can reject new work and drain all work that was already accepted.
@MainActor
final class AppModelClipboardMutationTaskOwner {
    enum State: Sendable, Equatable {
        case accepting
        case sealed
        case draining
        case stopped
    }

    private(set) var state: State = .accepting
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func submit(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Bool {
        guard state == .accepting else { return false }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.completeTask(id: id)
        }
        tasks[id] = task
        return true
    }

    /// Irreversibly rejects all future submissions while allowing accepted
    /// mutations to finish normally.
    func seal() {
        guard state == .accepting else { return }
        state = .sealed
    }

    /// Irreversibly seals the owner, waits for every accepted mutation, and
    /// leaves it stopped. Concurrent and repeated drains share the same barrier.
    func drainAndStop() async {
        switch state {
        case .stopped:
            return
        case .accepting, .sealed:
            state = .draining
        case .draining:
            break
        }

        guard !tasks.isEmpty else {
            finishDraining()
            return
        }

        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
    }

    private func completeTask(id: UUID) {
        tasks.removeValue(forKey: id)
        guard state == .draining, tasks.isEmpty else { return }
        finishDraining()
    }

    private func finishDraining() {
        guard state != .stopped else { return }
        state = .stopped
        let continuations = drainContinuations
        drainContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
