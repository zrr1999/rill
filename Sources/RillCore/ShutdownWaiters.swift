import Foundation

/// Continuations waiting for one owner to finish shutdown.
/// The owner stays the only place that decides when work is finished.
public struct ShutdownWaiters {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public mutating func add(_ continuation: CheckedContinuation<Void, Never>) {
        continuations.append(continuation)
    }

    public mutating func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
