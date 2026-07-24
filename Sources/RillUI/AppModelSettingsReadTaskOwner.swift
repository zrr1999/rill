import Foundation

enum AppModelSettingsReadTaskSlot: Hashable, Sendable {
    case initialSettingsLoad
    case storedSettingsDomainsRetry
    case privacySettingsRetry
    case deepgramCredentialRetry
    case scalarSettingsRetry(ScalarSettingsDomain)
}

/// Retains lifecycle-sensitive settings reads until they actually complete.
///
/// Replacing an active read cancels it without releasing ownership because a
/// store may ignore cooperative cancellation or be finishing credential
/// migration. Application shutdown therefore drains active and retired reads.
@MainActor
final class AppModelSettingsReadTaskOwner {
    enum State: Sendable, Equatable {
        case accepting
        case draining
        case stopped
    }

    private(set) var state: State = .accepting
    private var activeTaskIDs: [AppModelSettingsReadTaskSlot: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    var trackedTaskCount: Int {
        tasks.count
    }

    @discardableResult
    func replaceActive(
        in slot: AppModelSettingsReadTaskSlot,
        id: UUID,
        with task: Task<Void, Never>
    ) -> Bool {
        guard state == .accepting else {
            task.cancel()
            return false
        }

        if let activeID = activeTaskIDs[slot] {
            tasks[activeID]?.cancel()
        }
        tasks[id] = task
        activeTaskIDs[slot] = id
        return true
    }

    func isActive(
        in slot: AppModelSettingsReadTaskSlot,
        id: UUID
    ) -> Bool {
        state == .accepting && activeTaskIDs[slot] == id
    }

    /// Waits for the current task in one slot without taking ownership away
    /// from application shutdown. If the task is replaced while the caller is
    /// suspended, wait for the replacement as well so readiness never observes
    /// a gap between two generations.
    func waitForActiveTask(in slot: AppModelSettingsReadTaskSlot) async {
        while let taskID = activeTaskIDs[slot],
              let task = tasks[taskID] {
            await task.value
            guard activeTaskIDs[slot] != taskID else {
                // A task normally removes itself in `finish`. Keeping this
                // guard makes a broken owner invariant fail closed instead of
                // spinning on an already-completed task.
                return
            }
        }
    }

    func finish(
        in slot: AppModelSettingsReadTaskSlot,
        id: UUID
    ) {
        tasks.removeValue(forKey: id)
        if activeTaskIDs[slot] == id {
            activeTaskIDs[slot] = nil
        }
        guard state == .draining, tasks.isEmpty else { return }
        finishDraining()
    }

    func cancelAllAndDrain() async {
        switch state {
        case .stopped:
            return
        case .draining:
            await waitForDrain()
            return
        case .accepting:
            state = .draining
            activeTaskIDs.removeAll()
            for task in tasks.values {
                task.cancel()
            }
        }

        guard !tasks.isEmpty else {
            finishDraining()
            return
        }
        await waitForDrain()
    }

    private func waitForDrain() async {
        guard state != .stopped else { return }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
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
