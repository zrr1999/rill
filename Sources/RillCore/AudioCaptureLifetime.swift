import Foundation

/// A run-scoped, content-free authorization lifetime for transmitting live audio.
///
/// The state transition and transmission-permit acquisition are serialized by
/// one lock. A permit acquired before revocation represents an already
/// authorized transmission; after revocation no new permit can be acquired.
public final class AudioCaptureLifetime: @unchecked Sendable, Equatable {
    public enum RevocationReason: String, Codable, Sendable, Equatable, CaseIterable {
        case authorizationInvalidated
        case captureCancelled
        case captureSuperseded
        case serviceFailure
    }

    public enum State: Sendable, Equatable {
        case active
        case revoked(RevocationReason)
        case completed
    }

    /// Opaque proof that one transmission was authorized while the lifetime was active.
    public struct TransmissionPermit: Sendable, Equatable {
        public let runID: UUID
        fileprivate let lifetimeID: UUID
    }

    public let runID: UUID

    private let identity = UUID()
    private let lock = NSLock()
    private var storedState: State = .active
    private var didClaimTerminalStateStream = false
    private var terminalStateContinuation: AsyncStream<State>.Continuation?

    public init(runID: UUID) {
        self.runID = runID
    }

    public var state: State {
        lock.withLock { storedState }
    }

    public var isActive: Bool {
        lock.withLock {
            if case .active = storedState {
                return true
            }
            return false
        }
    }

    /// Atomically authorizes one transmission if revocation has not won the race.
    public func acquireTransmissionPermit() -> TransmissionPermit? {
        lock.withLock {
            guard case .active = storedState else { return nil }
            return TransmissionPermit(runID: runID, lifetimeID: identity)
        }
    }

    /// Revokes future transmission authorization. The first terminal transition wins.
    @discardableResult
    public func revoke(_ reason: RevocationReason) -> Bool {
        transition(to: .revoked(reason))
    }

    /// Cancels the capture lifetime without exposing content or policy details.
    @discardableResult
    public func cancel(reason: RevocationReason = .captureCancelled) -> Bool {
        revoke(reason)
    }

    /// Marks a normally finished capture complete. The first terminal transition wins.
    @discardableResult
    public func complete() -> Bool {
        transition(to: .completed)
    }

    /// Claims the one-shot terminal-state notification for this authorization.
    ///
    /// A terminal transition that wins before the stream is claimed is buffered,
    /// so a capture controller cannot miss a post-start service failure. Only one
    /// controller may claim the stream because terminal ownership must remain
    /// unambiguous for a run.
    public func claimTerminalStateStream() -> AsyncStream<State>? {
        let streamAndTerminalState:
            (AsyncStream<State>, AsyncStream<State>.Continuation, State?)? = lock.withLock {
            guard !didClaimTerminalStateStream else { return nil }
            didClaimTerminalStateStream = true

            let pair = AsyncStream.makeStream(
                of: State.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            switch storedState {
            case .active:
                terminalStateContinuation = pair.continuation
                return (pair.stream, pair.continuation, nil)
            case .revoked, .completed:
                return (pair.stream, pair.continuation, storedState)
            }
        }
        guard let (stream, continuation, terminalState) = streamAndTerminalState else { return nil }
        if let terminalState {
            continuation.yield(terminalState)
            continuation.finish()
        }
        return stream
    }

    private func transition(to terminalState: State) -> Bool {
        let transition: (Bool, AsyncStream<State>.Continuation?) = lock.withLock {
            guard case .active = storedState else { return (false, nil) }
            storedState = terminalState
            let continuation = terminalStateContinuation
            terminalStateContinuation = nil
            return (true, continuation)
        }
        guard transition.0 else { return false }
        transition.1?.yield(terminalState)
        transition.1?.finish()
        return true
    }

    public static func == (lhs: AudioCaptureLifetime, rhs: AudioCaptureLifetime) -> Bool {
        lhs === rhs
    }
}
