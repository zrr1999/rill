import Foundation
import VoxTypeCore

public actor EventBus {
    private var continuations: [UUID: AsyncStream<VoxTypeEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<VoxTypeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [id] _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    public func publish(_ event: VoxTypeEvent) {
        var terminated: [UUID] = []
        for (id, continuation) in continuations {
            if case .terminated = continuation.yield(event) {
                terminated.append(id)
            }
        }
        for id in terminated {
            continuations.removeValue(forKey: id)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
