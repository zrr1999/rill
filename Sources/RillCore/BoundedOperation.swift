import Foundation

public enum OperationDeadlineError: Error, Sendable, Equatable {
    case timedOut
    case capacityExceeded
    case stopped
}

/// A resource owner retains timed-out operations until the dependency actually returns.
public actor BoundedOperation {
    private let capacity: Int
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public init(maxConcurrentOperations: Int = 1) {
        precondition(maxConcurrentOperations > 0)
        capacity = maxConcurrentOperations
    }

    public var pendingOperationCount: Int { operations.count }

    public func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard !stopped else { throw OperationDeadlineError.stopped }
        guard operations.count < capacity else { throw OperationDeadlineError.capacityExceeded }
        let id = UUID()
        let race = DeadlineResult<Value>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let work = Task {
            defer { operations.removeValue(forKey: id) }
            do {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw OperationDeadlineError.timedOut }
                let value = try await operation()
                try Task.checkCancellation()
                guard clock.now < deadline else { throw OperationDeadlineError.timedOut }
                race.finish(.success(value))
            }
            catch { race.finish(.failure(error)) }
        }
        operations[id] = work
        let timer = Task {
            do {
                try await clock.sleep(until: deadline)
                race.finish(.failure(OperationDeadlineError.timedOut))
            } catch {}
        }
        defer { work.cancel(); timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.wait($0) }
        } onCancel: {
            work.cancel()
            timer.cancel()
            race.finish(.failure(CancellationError()))
        }
    }

    public func shutdown() async {
        stopped = true
        let accepted = Array(operations.values)
        for operation in accepted { operation.cancel() }
        for operation in accepted { await operation.value }
    }
}

private final class DeadlineResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func wait(_ continuation: CheckedContinuation<Value, Error>) {
        let ready: Result<Value, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil as Result<Value, Error>?
        }
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<Value, Error>) {
        let waiter = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Value, Error>? }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(with: result)
    }
}
