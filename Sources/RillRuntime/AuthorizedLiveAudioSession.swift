import Foundation
import RillCore

public enum LiveAudioAuthorizationRevocationReason: String, Sendable, Equatable, CaseIterable {
    case contextRestricted
    case privacySettingsUnavailable
    case processingDestinationUnavailable
    case cloudConfirmationRequired
    case policyBlocked
}

public enum LiveAudioSessionError: Error, LocalizedError, Sendable, Equatable {
    case authorizationInvalidated(LiveAudioAuthorizationRevocationReason)
    case monitorNotStarted
    case captureNotSealed
    case captureAlreadySealed

    public var errorDescription: String? {
        switch self {
        case .authorizationInvalidated:
            return "The live recording stopped because its privacy authorization changed."
        case .monitorNotStarted:
            return "The live recording privacy monitor was not started."
        case .captureNotSealed:
            return "The live recording was not sealed for background processing."
        case .captureAlreadySealed:
            return "The live recording was already sealed for background processing."
        }
    }
}

public enum LiveAudioSessionCancellationResult: Sendable, Equatable {
    case cancelled
    case queueOwned
    case alreadyTerminal
}

/// Thread-safe state shared by the session monitor and its one-shot processing lease.
/// It contains no application identity, text, or audio.
final class LiveAudioSessionAuthorizationState: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case monitoring
        case sealed
        case queueOwned
        case revoked(LiveAudioAuthorizationRevocationReason)
    }

    enum ControllerCancellationResult: Sendable, Equatable {
        case cancelled
        case queueOwned
        case alreadyTerminal
    }

    private let lock = NSLock()
    private var storedState: State = .monitoring

    var state: State {
        lock.withLock { storedState }
    }

    var isQueueOwned: Bool {
        lock.withLock {
            if case .queueOwned = storedState { return true }
            return false
        }
    }

    @discardableResult
    func seal() -> Bool {
        lock.withLock {
            guard case .monitoring = storedState else { return false }
            storedState = .sealed
            return true
        }
    }

    @discardableResult
    func revoke(_ reason: LiveAudioAuthorizationRevocationReason) -> Bool {
        lock.withLock {
            guard case .monitoring = storedState else { return false }
            storedState = .revoked(reason)
            return true
        }
    }

    @discardableResult
    func transferToQueue() -> Bool {
        lock.withLock {
            guard case .sealed = storedState else { return false }
            storedState = .queueOwned
            return true
        }
    }

    func cancelControllerOwnedCapture() -> ControllerCancellationResult {
        lock.withLock {
            switch storedState {
            case .monitoring, .sealed:
                storedState = .revoked(.policyBlocked)
                return .cancelled
            case .queueOwned:
                return .queueOwned
            case .revoked:
                return .alreadyTerminal
            }
        }
    }

    @discardableResult
    func cancelQueueOwnedCapture() -> Bool {
        lock.withLock {
            guard case .queueOwned = storedState else { return false }
            storedState = .revoked(.policyBlocked)
            return true
        }
    }
}

/// A run-scoped live-capture authorization that remains revocable until input
/// has stopped and the controller seals the capture for deferred processing.
public actor AuthorizedLiveAudioSession {
    public nonisolated let runID: UUID
    public nonisolated let workflow: WorkflowDefinition
    public nonisolated let audioLifetime: AudioCaptureLifetime
    public nonisolated let audioCaptureOptions: SpeechRecognitionRequestOptions

    private let processingLease: AuthorizedAudioProcessingLease
    private let authorizationState: LiveAudioSessionAuthorizationState
    private let monitorInterval: Duration
    private let validation: @Sendable () async -> LiveAudioAuthorizationRevocationReason?
    private let revocationHandler: @Sendable (
        UUID,
        LiveAudioAuthorizationRevocationReason
    ) async -> Void
    private var monitorTask: Task<Void, Never>?
    private var monitorStarted = false

    init(
        runID: UUID,
        workflow: WorkflowDefinition,
        audioLifetime: AudioCaptureLifetime,
        processingLease: AuthorizedAudioProcessingLease,
        authorizationState: LiveAudioSessionAuthorizationState,
        monitorInterval: Duration,
        validation: @escaping @Sendable () async -> LiveAudioAuthorizationRevocationReason?,
        revocationHandler: @escaping @Sendable (
            UUID,
            LiveAudioAuthorizationRevocationReason
        ) async -> Void
    ) {
        self.runID = runID
        self.workflow = workflow
        self.audioLifetime = audioLifetime
        self.processingLease = processingLease
        self.authorizationState = authorizationState
        self.monitorInterval = monitorInterval > .zero ? monitorInterval : .milliseconds(50)
        self.validation = validation
        self.revocationHandler = revocationHandler
        audioCaptureOptions = processingLease.audioCaptureOptions
    }

    public func recordingStarted() { processingLease.contextPreparation?.recordingStarted() }

    /// Performs an immediate sink-adjacent check before capture starts, then
    /// monitors focus and settings until the stopped input is sealed.
    public func startMonitoring() async throws {
        if monitorStarted {
            guard case .monitoring = authorizationState.state,
                  audioLifetime.isActive else {
                throw currentInvalidationError()
            }
            return
        }
        monitorStarted = true

        if let reason = await validation() {
            await invalidate(reason, notifyController: false)
            throw LiveAudioSessionError.authorizationInvalidated(reason)
        }
        guard case .monitoring = authorizationState.state,
              audioLifetime.isActive else {
            throw currentInvalidationError()
        }

        monitorTask = Task { [weak self, monitorInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: monitorInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if let reason = await self.validation() {
                    await self.invalidate(reason, notifyController: true)
                    return
                }
                guard await self.shouldContinueMonitoring() else { return }
            }
        }
    }

    /// Called only after `finishCaptureDeferred()` has stopped microphone input
    /// and closed the audio-chunk boundary. It revalidates the latest focus and
    /// settings, then freezes that decision for the already-captured audio.
    public func sealCapture() async throws {
        guard monitorStarted else {
            throw LiveAudioSessionError.monitorNotStarted
        }
        switch authorizationState.state {
        case .sealed, .queueOwned:
            throw LiveAudioSessionError.captureAlreadySealed
        case .revoked(let reason):
            throw LiveAudioSessionError.authorizationInvalidated(reason)
        case .monitoring:
            break
        }

        if let reason = await validation() {
            await invalidate(reason, notifyController: false)
            throw LiveAudioSessionError.authorizationInvalidated(reason)
        }
        guard audioLifetime.isActive else {
            throw currentInvalidationError()
        }
        guard authorizationState.seal() else {
            throw currentInvalidationError()
        }
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Returns the processing lease only after the capture-stop boundary passed
    /// its final live-session check.
    public func processingLeaseForEnqueue() throws -> AuthorizedAudioProcessingLease {
        switch authorizationState.state {
        case .monitoring:
            throw LiveAudioSessionError.captureNotSealed
        case .revoked(let reason):
            throw LiveAudioSessionError.authorizationInvalidated(reason)
        case .sealed:
            break
        case .queueOwned:
            throw LiveAudioSessionError.captureAlreadySealed
        }
        guard audioLifetime.isActive else {
            throw currentInvalidationError()
        }
        return processingLease
    }

    /// Cancels a session while it is still owned by a capture controller. Once
    /// the lease is enqueued, the queue owns cancellation and cleanup.
    @discardableResult
    public func cancel() -> LiveAudioSessionCancellationResult {
        monitorTask?.cancel()
        monitorTask = nil
        switch authorizationState.cancelControllerOwnedCapture() {
        case .cancelled:
            processingLease.contextPreparation?.cancel()
            _ = audioLifetime.cancel()
            return .cancelled
        case .queueOwned:
            return .queueOwned
        case .alreadyTerminal:
            return .alreadyTerminal
        }
    }

    private func shouldContinueMonitoring() -> Bool {
        guard case .monitoring = authorizationState.state else { return false }
        return audioLifetime.isActive
    }

    private func invalidate(
        _ reason: LiveAudioAuthorizationRevocationReason,
        notifyController: Bool
    ) async {
        guard authorizationState.revoke(reason) else { return }
        processingLease.contextPreparation?.cancel()
        _ = audioLifetime.revoke(.authorizationInvalidated)
        monitorTask?.cancel()
        monitorTask = nil
        if notifyController {
            await revocationHandler(runID, reason)
        }
    }

    private func currentInvalidationError() -> LiveAudioSessionError {
        if case .revoked(let reason) = authorizationState.state {
            return .authorizationInvalidated(reason)
        }
        return .authorizationInvalidated(.policyBlocked)
    }
}
