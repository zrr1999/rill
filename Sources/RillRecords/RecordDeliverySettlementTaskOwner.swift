import Foundation

/// Retains committed-output delivery leases until their Record graph update is
/// durable. Retrying completion is safe because the output action is not run
/// again; releasing the lease as a failed delivery would make it selectable
/// and could duplicate an irreversible side effect.
package actor RecordDeliverySettlementTaskOwner {
    private let deliveryCoordinator: RecordDeliveryCoordinator
    private let retryDelay: Duration
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var hasBegunShutdown = false

    package init(
        deliveryCoordinator: RecordDeliveryCoordinator,
        retryDelay: Duration = .milliseconds(250)
    ) {
        self.deliveryCoordinator = deliveryCoordinator
        self.retryDelay = retryDelay
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    package func schedule(leaseID: UUID) {
        guard !hasBegunShutdown, tasks[leaseID] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.retryCompletion(leaseID: leaseID)
        }
        tasks[leaseID] = task
    }

    package func shutdown() async {
        hasBegunShutdown = true
        let runningTasks = Array(tasks.values)
        for task in runningTasks {
            task.cancel()
        }
        for task in runningTasks {
            await task.value
        }
        tasks.removeAll()
    }

    private func retryCompletion(leaseID: UUID) async {
        defer { tasks[leaseID] = nil }
        while !Task.isCancelled {
            do {
                _ = try await deliveryCoordinator.completeDelivery(leaseID)
                return
            } catch {
                do {
                    try await Task.sleep(for: retryDelay)
                } catch {
                    return
                }
            }
        }
    }
}
