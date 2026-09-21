import Foundation
import RillCore

/// A single-use authorization for one deferred audio-processing run.
///
/// The lease is bound to the exact run and workflow captured at issuance. Only
/// the audio capture options are visible outside RillRuntime; the authorized
/// context and policy evidence remain behind the runtime claim/finalization boundary.
public actor AuthorizedAudioProcessingLease {
    struct Payload: Sendable {
        let runID: UUID
        let workflow: WorkflowDefinition
        let sourcePrivacyContext: ContextSnapshot
        let authorizedContext: ContextSnapshot
        let recognitionOptions: SpeechRecognitionRequestOptions
        let policySettings: PrivacyPolicySettings
        let decision: PrivacyPolicyDecision
        let processingDestinations: [PrivacyProcessingDestination]
        let liveAuthorizationState: LiveAudioSessionAuthorizationState?
        let audioLifetime: AudioCaptureLifetime?
        let contextPreparation: RunContextPreparation?

        init(
            runID: UUID,
            workflow: WorkflowDefinition,
            sourcePrivacyContext: ContextSnapshot,
            authorizedContext: ContextSnapshot,
            recognitionOptions: SpeechRecognitionRequestOptions,
            policySettings: PrivacyPolicySettings,
            decision: PrivacyPolicyDecision,
            processingDestinations: [PrivacyProcessingDestination],
            liveAuthorizationState: LiveAudioSessionAuthorizationState? = nil,
            audioLifetime: AudioCaptureLifetime? = nil,
            contextPreparation: RunContextPreparation? = nil
        ) {
            self.runID = runID
            self.workflow = workflow
            self.sourcePrivacyContext = sourcePrivacyContext
            self.authorizedContext = authorizedContext
            self.recognitionOptions = recognitionOptions
            self.policySettings = policySettings
            self.decision = decision
            self.processingDestinations = processingDestinations
            self.liveAuthorizationState = liveAuthorizationState
            self.audioLifetime = audioLifetime
            self.contextPreparation = contextPreparation
        }
    }

    public nonisolated let audioCaptureOptions: SpeechRecognitionRequestOptions
    nonisolated let didSatisfyCloudConfirmation: Bool
    nonisolated let processingDestinationsAtIssuance: [PrivacyProcessingDestination]

    nonisolated let runID: UUID
    nonisolated let workflow: WorkflowDefinition
    private nonisolated let liveAuthorizationState: LiveAudioSessionAuthorizationState?
    private nonisolated let audioLifetime: AudioCaptureLifetime?
    nonisolated let contextPreparation: RunContextPreparation?
    private let payload: Payload
    private let claimValidator: @Sendable (
        Payload,
        WorkflowTriggerEvent?
    ) async throws -> AuthorizedAudioProcessingClaim.PolicyState
    private let finalValidator: @Sendable (
        Payload,
        AuthorizedAudioProcessingClaim.PolicyState
    ) async throws -> AuthorizedWorkflowRunContext
    private var wasClaimed = false

    init(
        payload: Payload,
        claimValidator: @escaping @Sendable (
            Payload,
            WorkflowTriggerEvent?
        ) async throws -> AuthorizedAudioProcessingClaim.PolicyState,
        finalValidator: @escaping @Sendable (
            Payload,
            AuthorizedAudioProcessingClaim.PolicyState
        ) async throws -> AuthorizedWorkflowRunContext
    ) {
        self.payload = payload
        self.claimValidator = claimValidator
        self.finalValidator = finalValidator
        runID = payload.runID
        workflow = payload.workflow
        audioCaptureOptions = payload.recognitionOptions
        didSatisfyCloudConfirmation = payload.decision.requiresCloudConfirmation
        processingDestinationsAtIssuance = payload.processingDestinations
        liveAuthorizationState = payload.liveAuthorizationState
        audioLifetime = payload.audioLifetime
        contextPreparation = payload.contextPreparation
    }

    /// Atomically transfers a sealed live capture from its controller to the
    /// queue. Non-live leases have no controller ownership boundary.
    nonisolated func acceptQueueOwnership() -> Bool {
        guard let liveAuthorizationState else { return true }
        return liveAuthorizationState.transferToQueue()
    }

    /// Claims this lease before a deferred capture is resolved. The returned
    /// claim remains opaque outside RillRuntime and must be finalized after
    /// capture resolution before recognition begins.
    func claim(
        triggerEvent: WorkflowTriggerEvent?
    ) async throws -> AuthorizedAudioProcessingClaim {
        guard !wasClaimed else {
            throw PrivacyRunGate.GateError.audioProcessingAuthorizationAlreadyConsumed
        }
        wasClaimed = true
        if let liveAuthorizationState = payload.liveAuthorizationState {
            guard liveAuthorizationState.isQueueOwned,
                  payload.audioLifetime?.isActive == true else {
                throw PrivacyRunGate.GateError.audioProcessingAuthorizationInvalid
            }
        }
        let policyState = try await claimValidator(payload, triggerEvent)
        return AuthorizedAudioProcessingClaim(
            payload: payload,
            policyState: policyState,
            finalValidator: finalValidator
        )
    }

    /// Invalidates any live-capture lifetime still attached to this lease.
    /// Used when queue ownership is abandoned during application shutdown.
    public nonisolated func cancel() {
        contextPreparation?.cancel()
        guard let liveAuthorizationState else {
            _ = audioLifetime?.cancel()
            return
        }
        guard liveAuthorizationState.cancelQueueOwnedCapture() else { return }
        _ = audioLifetime?.cancel()
    }
}

/// Runtime-internal proof that a lease passed its pre-resolution checks.
/// Finalization is also single-use so authorization cannot be replayed across
/// multiple recognition attempts.
actor AuthorizedAudioProcessingClaim {
    struct PolicyState: Sendable {
        let settings: PrivacyPolicySettings
        let decision: PrivacyPolicyDecision
        let processingDestinations: [PrivacyProcessingDestination]
        let cloudConfirmationSatisfied: Bool
    }

    private let payload: AuthorizedAudioProcessingLease.Payload
    private let policyState: PolicyState
    private let finalValidator: @Sendable (
        AuthorizedAudioProcessingLease.Payload,
        PolicyState
    ) async throws -> AuthorizedWorkflowRunContext
    private var wasFinalized = false

    init(
        payload: AuthorizedAudioProcessingLease.Payload,
        policyState: PolicyState,
        finalValidator: @escaping @Sendable (
            AuthorizedAudioProcessingLease.Payload,
            PolicyState
        ) async throws -> AuthorizedWorkflowRunContext
    ) {
        self.payload = payload
        self.policyState = policyState
        self.finalValidator = finalValidator
    }

    func finalize() async throws -> (runID: UUID, authorizedContext: AuthorizedWorkflowRunContext) {
        guard !wasFinalized else {
            throw PrivacyRunGate.GateError.audioProcessingAuthorizationAlreadyConsumed
        }
        wasFinalized = true
        return (
            payload.runID,
            try await finalValidator(payload, policyState)
        )
    }
}
