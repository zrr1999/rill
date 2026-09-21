import Foundation

public enum OperationDeadlineError: Error, Sendable { case timedOut }

/// Unlike task-group teardown, returning at the deadline never joins an uncooperative dependency.
public enum BoundedOperation {
    public static func run<Value: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = DeadlineResult<Value>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let work = Task {
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
