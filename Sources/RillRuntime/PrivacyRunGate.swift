import Foundation
import RillCore

public struct AuthorizedPrivacyContext: Sendable, Equatable {
    public var context: ContextSnapshot
    public var decision: PrivacyPolicyDecision

    public init(context: ContextSnapshot, decision: PrivacyPolicyDecision) {
        self.context = context
        self.decision = decision
    }
}

extension PrivacyRunGate {
    /// Evaluates a group run without ever invoking the confirmation provider.
    /// Source identity comes from the exact actor-owned item snapshot rather
    /// than whichever application happens to be frontmost later.
    public func evaluateNonInteractiveClipboardGroupRun(
        source: ClipboardGroupRunAuthorizationSource,
        workflow: WorkflowDefinition
    ) async -> ClipboardGroupRunAuthorizationEvaluation {
        guard WorkflowExecutionPolicy.decision(
            for: workflow,
            on: .clipboardGroupEvent
        ) == .supported,
            let configuration = try? workflow
                .parseClipboardGroupAutomationConfiguration()
        else {
            return .blocked(reason: .executionSurfaceUnsupported)
        }
        guard configuration.rule.matchResult(for: source.descriptor).matched else {
            return .blocked(reason: .triggerMismatch)
        }
        guard configuration.actionKind == .editItem,
              workflow.pipeline.outputActions.count == 1,
              workflow.pipeline.outputActions[0].id == "stack.push" else {
            return .blocked(reason: .actionPlanUnsupported)
        }
        guard source.subject.contentKind == .text,
              source.subject.hasTransferableContent else {
            return .blocked(reason: .sourceContentUnsupported)
        }
        guard !source.subject.excludesWorkflowCapture else {
            return .blocked(reason: .sourceExcludedFromWorkflowCapture)
        }

        let policy: EvaluatedPolicy
        do {
            policy = try await evaluatePolicy(
                context: source.privacyContext,
                workflow: workflow,
                invocation: .clipboardItem(
                    subject: source.subject,
                    operation: .replace
                )
            )
        } catch GateError.settingsUnavailable {
            return .blocked(reason: .privacySettingsUnavailable)
        } catch GateError.processingDestinationUnavailable {
            return .blocked(reason: .processingDestinationUnavailable)
        } catch {
            return .blocked(reason: .privacySettingsUnavailable)
        }

        guard policy.decision.allowsWorkflowCapture else {
            return .blocked(reason: .workflowCaptureBlocked)
        }
        guard !policy.decision.blocksCloudProcessing else {
            return .blocked(reason: .cloudProcessingBlocked)
        }
        guard !policy.decision.requiresCloudConfirmation else {
            return .blocked(reason: .cloudConfirmationRequired)
        }
        return .ready(processingDestinations: policy.processingDestinations)
    }
}

public struct PrivacyRunGate: Sendable {
    public enum GateError: Error, LocalizedError, Equatable {
        case settingsUnavailable
        case processingDestinationUnavailable
        case cloudProcessingBlocked
        case cloudConfirmationDeclined
        case policyChangedDuringAuthorization
        case contextChangedDuringAuthorization
        case clipboardItemOperationUnsupported
        case clipboardItemContentUnsupported
        case clipboardItemContentUnavailable
        case clipboardItemExcludedFromWorkflowCapture
        case clipboardItemSourceReplacementUnavailable
        case clipboardItemSourceReplacementAmbiguous
        case clipboardItemSourcePrivacyBlocked
        case clipboardItemUnavailable
        case clipboardItemChangedDuringAuthorization
        case workflowRunAuthorizationAlreadyConsumed
        case audioProcessingAuthorizationInvalid
        case audioProcessingAuthorizationAlreadyConsumed

        public var errorDescription: String? {
            switch self {
            case .settingsUnavailable:
                return "Privacy settings are unavailable, so this run was blocked."
            case .processingDestinationUnavailable:
                return "The workflow contains an unclassified processing destination, so this run was blocked."
            case .cloudProcessingBlocked:
                return "Cloud processing is blocked for the current application."
            case .cloudConfirmationDeclined:
                return "Cloud processing was cancelled before audio left this Mac."
            case .policyChangedDuringAuthorization:
                return "Privacy settings changed during authorization. Please try again."
            case .contextChangedDuringAuthorization:
                return "The active application or clipboard changed during privacy authorization. Please try again."
            case .clipboardItemOperationUnsupported:
                return "The clipboard item operation cannot run as a workflow."
            case .clipboardItemContentUnsupported:
                return "Only stored text items can be replayed through a workflow."
            case .clipboardItemContentUnavailable:
                return "The stored clipboard item no longer has transferable content."
            case .clipboardItemExcludedFromWorkflowCapture:
                return "The stored clipboard item is excluded from workflow processing."
            case .clipboardItemSourceReplacementUnavailable:
                return "The workflow does not contain an action that can replace the source clipboard item."
            case .clipboardItemSourceReplacementAmbiguous:
                return "The workflow contains more than one action that would replace the source clipboard item."
            case .clipboardItemSourcePrivacyBlocked:
                return "Privacy rules for the source application block workflow processing of this stored item."
            case .clipboardItemUnavailable:
                return "The stored clipboard item is no longer available."
            case .clipboardItemChangedDuringAuthorization:
                return "The stored clipboard item changed during authorization. Please try again."
            case .workflowRunAuthorizationAlreadyConsumed:
                return "The workflow authorization was already used, so this run was blocked."
            case .audioProcessingAuthorizationInvalid:
                return "The queued audio authorization no longer matches this run, so processing was blocked."
            case .audioProcessingAuthorizationAlreadyConsumed:
                return "The queued audio authorization was already used, so processing was blocked."
            }
        }
    }

    private struct EvaluatedPolicy: Sendable, Equatable {
        var settings: PrivacyPolicySettings
        var decision: PrivacyPolicyDecision
        var processingDestinations: [PrivacyProcessingDestination]

        static func == (lhs: EvaluatedPolicy, rhs: EvaluatedPolicy) -> Bool {
            PrivacyRunGate.settingsAreEquivalent(lhs.settings, rhs.settings)
                && lhs.decision == rhs.decision
                && lhs.processingDestinations == rhs.processingDestinations
        }
    }

    private struct CapturedPolicyContext: Sendable {
        var sourcePrivacyContext: ContextSnapshot
        var authorizedContext: ContextSnapshot
        var policy: EvaluatedPolicy
    }

    private struct ReusableCloudConfirmation: Sendable {
        var sourcePrivacyContext: ContextSnapshot
        var policy: EvaluatedPolicy
    }

    private let settingsProvider: @Sendable () async throws -> PrivacyPolicySettings
    private let cloudConfirmationProvider: @Sendable (
        WorkflowDefinition,
        PrivacyPolicyDecision,
        [PrivacyProcessingDestination]
    ) async -> Bool
    private let destinationClassifier: @Sendable (
        WorkflowDefinition,
        WorkflowRunInvocation
    ) -> WorkflowPrivacyDestinationClassification

    public init(
        settingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings,
        cloudConfirmationProvider: @escaping @Sendable (
            WorkflowDefinition,
            PrivacyPolicyDecision,
            [PrivacyProcessingDestination]
        ) async -> Bool
    ) {
        self.settingsProvider = settingsProvider
        self.cloudConfirmationProvider = cloudConfirmationProvider
        destinationClassifier = { workflow, invocation in
            WorkflowPrivacyDestinationClassifier.classify(
                workflow,
                invocation: invocation
            )
        }
    }

    init(
        settingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings,
        cloudConfirmationProvider: @escaping @Sendable (
            WorkflowDefinition,
            PrivacyPolicyDecision,
            [PrivacyProcessingDestination]
        ) async -> Bool,
        destinationClassifier: @escaping @Sendable (
            WorkflowDefinition
        ) -> WorkflowPrivacyDestinationClassification
    ) {
        self.settingsProvider = settingsProvider
        self.cloudConfirmationProvider = cloudConfirmationProvider
        self.destinationClassifier = { workflow, _ in
            destinationClassifier(workflow)
        }
    }

    init(
        settingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings,
        cloudConfirmationProvider: @escaping @Sendable (
            WorkflowDefinition,
            PrivacyPolicyDecision,
            [PrivacyProcessingDestination]
        ) async -> Bool,
        invocationDestinationClassifier: @escaping @Sendable (
            WorkflowDefinition,
            WorkflowRunInvocation
        ) -> WorkflowPrivacyDestinationClassification
    ) {
        self.settingsProvider = settingsProvider
        self.cloudConfirmationProvider = cloudConfirmationProvider
        destinationClassifier = invocationDestinationClassifier
    }

    public func authorize(
        context: ContextSnapshot,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedPrivacyContext {
        let evaluatedPolicy = try await authorizePolicy(context: context, workflow: workflow)
        let decision = evaluatedPolicy.decision
        return AuthorizedPrivacyContext(
            context: context.applying(decision),
            decision: decision
        )
    }

    private func authorizePolicy(
        context: ContextSnapshot,
        workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation = .capture
    ) async throws -> EvaluatedPolicy {
        try await authorizePolicy(
            context: context,
            workflow: workflow,
            invocation: invocation,
            reusableCloudConfirmationPolicy: nil
        )
    }

    private func authorizePolicy(
        context: ContextSnapshot,
        workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation,
        reusableCloudConfirmationPolicy: EvaluatedPolicy?
    ) async throws -> EvaluatedPolicy {
        let evaluatedPolicy = try await evaluatePolicy(
            context: context,
            workflow: workflow,
            invocation: invocation
        )
        let decision = evaluatedPolicy.decision
        if decision.blocksCloudProcessing {
            throw GateError.cloudProcessingBlocked
        }
        if decision.requiresCloudConfirmation,
           reusableCloudConfirmationPolicy != evaluatedPolicy {
            let confirmed = await cloudConfirmationProvider(
                workflow,
                decision,
                evaluatedPolicy.processingDestinations
            )
            guard confirmed else {
                throw GateError.cloudConfirmationDeclined
            }
        }

        let currentPolicy = try await evaluatePolicy(
            context: context,
            workflow: workflow,
            invocation: invocation
        )
        guard currentPolicy == evaluatedPolicy else {
            throw GateError.policyChangedDuringAuthorization
        }
        return currentPolicy
    }

    /// Evaluates the same policy and destination classification used by
    /// `authorize`, but never calls the confirmation provider and never grants
    /// an authorization token.
    public func evaluate(
        context: ContextSnapshot,
        workflow: WorkflowDefinition
    ) async -> PrivacyRunEvaluation {
        await evaluate(
            context: context,
            workflow: workflow,
            invocation: .capture
        )
    }

    public func evaluate(
        context: ContextSnapshot,
        workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation
    ) async -> PrivacyRunEvaluation {
        do {
            let evaluatedPolicy = try await evaluatePolicy(
                context: context,
                workflow: workflow,
                invocation: invocation
            )
            return Self.project(evaluatedPolicy.decision)
        } catch GateError.settingsUnavailable {
            return PrivacyRunEvaluation(
                status: .blocked,
                reasons: [.privacySettingsUnavailable]
            )
        } catch GateError.processingDestinationUnavailable {
            return PrivacyRunEvaluation(
                status: .blocked,
                reasons: [.processingDestinationUnavailable]
            )
        } catch {
            // `evaluatePolicy` has a closed error surface. Preserve fail-closed
            // behavior if that implementation changes without widening this DTO.
            return PrivacyRunEvaluation(
                status: .blocked,
                reasons: [.privacySettingsUnavailable]
            )
        }
    }

    public func captureAuthorizedContext(
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedPrivacyContext {
        let capture = try await captureAuthorizedPolicyContext(
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            workflow: workflow
        )
        return AuthorizedPrivacyContext(
            context: capture.authorizedContext,
            decision: capture.policy.decision
        )
    }

    private func captureAuthorizedPolicyContext(
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation = .capture
    ) async throws -> CapturedPolicyContext {
        var reusableCloudConfirmation: ReusableCloudConfirmation?
        for _ in 0..<2 {
            let privacyContext = await privacyContextProvider()
            let reusablePolicy: EvaluatedPolicy?
            if let reusableCloudConfirmation,
               Self.hasSamePrivacySourceMetadata(
                   reusableCloudConfirmation.sourcePrivacyContext,
                   privacyContext
               ) {
                reusablePolicy = reusableCloudConfirmation.policy
            } else {
                reusablePolicy = nil
            }
            let authorizedPolicy = try await authorizePolicy(
                context: privacyContext,
                workflow: workflow,
                invocation: invocation,
                reusableCloudConfirmationPolicy: reusablePolicy
            )
            let fullContext = await contextProvider(authorizedPolicy.decision)
            guard Self.representsSameSource(privacyContext, fullContext) else {
                reusableCloudConfirmation = authorizedPolicy.decision.requiresCloudConfirmation
                    ? ReusableCloudConfirmation(
                        sourcePrivacyContext: privacyContext,
                        policy: authorizedPolicy
                    )
                    : nil
                continue
            }
            let currentPolicy = try await evaluatePolicy(
                context: privacyContext,
                workflow: workflow,
                invocation: invocation
            )
            guard currentPolicy == authorizedPolicy else {
                throw GateError.policyChangedDuringAuthorization
            }
            return CapturedPolicyContext(
                sourcePrivacyContext: privacyContext,
                authorizedContext: fullContext.applying(currentPolicy.decision),
                policy: currentPolicy
            )
        }
        throw GateError.contextChangedDuringAuthorization
    }

    public func captureAuthorizedWorkflowRunContext(
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        recognitionOptionsProvider: @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext {
        let authorization = try await captureAuthorizedContext(
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            workflow: workflow
        )
        return AuthorizedWorkflowRunContext(
            workflow: workflow,
            contextSnapshot: authorization.context,
            recognitionOptions: await recognitionOptionsProvider(
                workflow,
                authorization.context
            ),
            invocation: .capture
        )
    }

    /// Authorizes a stored text item for replay/replace without consulting the
    /// workflow recognizer or deriving recognition options. The returned
    /// context is bound to the exact content-free item subject and operation.
    public func captureAuthorizedClipboardItemRunContext(
        subject: ClipboardItemDryRunSubject,
        operation: ClipboardItemDryRunOperation,
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext {
        let invocation = try validatedClipboardItemRunInvocation(
            subject: subject,
            operation: operation,
            workflow: workflow
        )
        let capture = try await captureAuthorizedPolicyContext(
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            workflow: workflow,
            invocation: invocation
        )
        return AuthorizedWorkflowRunContext(
            workflow: workflow,
            contextSnapshot: capture.authorizedContext,
            recognitionOptions: .empty,
            invocation: invocation
        )
    }

    /// Authorizes a stored item against both its exact source application and
    /// the current action target. The source policy is checked before any cloud
    /// confirmation and again after target authorization.
    public func captureAuthorizedClipboardItemRunContext(
        source: ClipboardItemRunAuthorizationSource,
        operation: ClipboardItemDryRunOperation,
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedWorkflowRunContext {
        let invocation = try validatedClipboardItemRunInvocation(
            subject: source.subject,
            operation: operation,
            workflow: workflow
        )
        let sourcePolicy = try await evaluatePolicy(
            context: source.privacyContext,
            workflow: workflow,
            invocation: invocation
        )
        guard sourcePolicy.decision.allowsWorkflowCapture else {
            throw GateError.clipboardItemSourcePrivacyBlocked
        }
        guard !sourcePolicy.decision.blocksCloudProcessing else {
            throw GateError.cloudProcessingBlocked
        }

        let capture = try await captureAuthorizedPolicyContext(
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            workflow: workflow,
            invocation: invocation
        )
        let currentSourcePolicy = try await evaluatePolicy(
            context: source.privacyContext,
            workflow: workflow,
            invocation: invocation
        )
        guard currentSourcePolicy == sourcePolicy else {
            throw GateError.policyChangedDuringAuthorization
        }
        return AuthorizedWorkflowRunContext(
            workflow: workflow,
            contextSnapshot: capture.authorizedContext,
            recognitionOptions: .empty,
            invocation: invocation
        )
    }

    private func validatedClipboardItemRunInvocation(
        subject: ClipboardItemDryRunSubject,
        operation: ClipboardItemDryRunOperation,
        workflow: WorkflowDefinition
    ) throws -> WorkflowRunInvocation {
        guard operation == .replay || operation == .replace else {
            throw GateError.clipboardItemOperationUnsupported
        }
        guard subject.contentKind == .text else {
            throw GateError.clipboardItemContentUnsupported
        }
        guard subject.hasTransferableContent else {
            throw GateError.clipboardItemContentUnavailable
        }
        guard !subject.excludesWorkflowCapture else {
            throw GateError.clipboardItemExcludedFromWorkflowCapture
        }
        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
        }
        switch WorkflowComponentProfileRegistry().clipboardItemSourceReplacementPlan(
            for: workflow,
            operation: operation
        ) {
        case .notRequested, .exactlyOne:
            break
        case .unavailable:
            throw GateError.clipboardItemSourceReplacementUnavailable
        case .ambiguous:
            throw GateError.clipboardItemSourceReplacementAmbiguous
        }

        return WorkflowRunInvocation.clipboardItem(
            subject: subject,
            operation: operation
        )
    }

    /// Authorizes capture and issues a one-shot lease for deferred processing.
    /// The queue must claim the lease before resolving the capture and finalize
    /// that claim against the same gate before recognizing the captured audio.
    public func issueAudioProcessingLease(
        runID: UUID,
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        recognitionOptionsProvider: @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions,
        workflow: WorkflowDefinition
    ) async throws -> AuthorizedAudioProcessingLease {
        try await issueAudioProcessingLease(
            runID: runID,
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            recognitionOptionsProvider: recognitionOptionsProvider,
            workflow: workflow,
            liveAuthorizationState: nil,
            audioLifetime: nil
        )
    }

    /// Issues a continuously revocable live-capture session. The caller must
    /// start monitoring before capture, seal only after input has stopped, and
    /// enqueue only the lease returned by the sealed session.
    public func issueLiveAudioSession(
        runID: UUID,
        privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        recognitionOptionsProvider: @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions,
        workflow: WorkflowDefinition,
        monitorInterval: Duration = .milliseconds(50),
        revocationHandler: @escaping @Sendable (
            UUID,
            LiveAudioAuthorizationRevocationReason
        ) async -> Void
    ) async throws -> AuthorizedLiveAudioSession {
        let liveAuthorizationState = LiveAudioSessionAuthorizationState()
        let audioLifetime = AudioCaptureLifetime(runID: runID)
        let lease = try await issueAudioProcessingLease(
            runID: runID,
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            recognitionOptionsProvider: recognitionOptionsProvider,
            workflow: workflow,
            liveAuthorizationState: liveAuthorizationState,
            audioLifetime: audioLifetime
        )
        return AuthorizedLiveAudioSession(
            runID: runID,
            workflow: workflow,
            audioLifetime: audioLifetime,
            processingLease: lease,
            authorizationState: liveAuthorizationState,
            monitorInterval: monitorInterval,
            validation: { [self] in
                let context = await privacyContextProvider()
                return await self.liveAudioRevocationReason(
                    context: context,
                    workflow: workflow,
                    expectedDestinations: lease.processingDestinationsAtIssuance,
                    cloudConfirmationSatisfied: lease.didSatisfyCloudConfirmation
                )
            },
            revocationHandler: revocationHandler
        )
    }

    private func issueAudioProcessingLease(
        runID: UUID,
        privacyContextProvider: @Sendable () async -> ContextSnapshot,
        contextProvider: @Sendable (PrivacyPolicyDecision) async -> ContextSnapshot,
        recognitionOptionsProvider: @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions,
        workflow: WorkflowDefinition,
        liveAuthorizationState: LiveAudioSessionAuthorizationState?,
        audioLifetime: AudioCaptureLifetime?
    ) async throws -> AuthorizedAudioProcessingLease {
        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            throw SessionCoordinator.SessionError.unsupportedWorkflow(issue)
        }
        let capture = try await captureAuthorizedPolicyContext(
            privacyContextProvider: privacyContextProvider,
            contextProvider: contextProvider,
            workflow: workflow
        )
        let recognitionOptions = await recognitionOptionsProvider(
            workflow,
            capture.authorizedContext
        )
        let finalPolicy = try await evaluatePolicy(
            context: capture.sourcePrivacyContext,
            workflow: workflow
        )
        guard finalPolicy == capture.policy else {
            throw GateError.policyChangedDuringAuthorization
        }
        return AuthorizedAudioProcessingLease(
            payload: .init(
                runID: runID,
                workflow: workflow,
                sourcePrivacyContext: capture.sourcePrivacyContext,
                authorizedContext: capture.authorizedContext,
                recognitionOptions: recognitionOptions,
                policySettings: finalPolicy.settings,
                decision: finalPolicy.decision,
                processingDestinations: finalPolicy.processingDestinations,
                liveAuthorizationState: liveAuthorizationState,
                audioLifetime: audioLifetime
            ),
            claimValidator: { [self] payload, triggerEvent in
                try await self.claimAudioProcessingPayload(
                    payload,
                    triggerEvent: triggerEvent
                )
            },
            finalValidator: { [self] payload, policyState in
                try await self.finalizeAudioProcessingPayload(
                    payload,
                    policyState: policyState
                )
            }
        )
    }

    private func liveAudioRevocationReason(
        context: ContextSnapshot,
        workflow: WorkflowDefinition,
        expectedDestinations: [PrivacyProcessingDestination],
        cloudConfirmationSatisfied: Bool
    ) async -> LiveAudioAuthorizationRevocationReason? {
        let policy: EvaluatedPolicy
        do {
            policy = try await evaluatePolicy(context: context, workflow: workflow)
        } catch GateError.settingsUnavailable {
            return .privacySettingsUnavailable
        } catch GateError.processingDestinationUnavailable {
            return .processingDestinationUnavailable
        } catch {
            return .privacySettingsUnavailable
        }

        let usesCloud = expectedDestinations.contains(where: \.isCloud)
        if policy.processingDestinations != expectedDestinations {
            return .processingDestinationUnavailable
        }
        if usesCloud && (
            policy.decision.reasons.contains(.unknownFocusContext)
                || policy.decision.reasons.contains(.secureInput)
        ) {
            return .contextRestricted
        }
        if usesCloud,
           policy.decision.reasons.contains(.sensitiveApplication),
           !policy.decision.allowsWorkflowCapture {
            return .contextRestricted
        }
        if usesCloud, policy.decision.blocksCloudProcessing {
            return .policyBlocked
        }
        if usesCloud,
           policy.decision.requiresCloudConfirmation,
           !cloudConfirmationSatisfied {
            return .cloudConfirmationRequired
        }
        return nil
    }

    private func claimAudioProcessingPayload(
        _ payload: AuthorizedAudioProcessingLease.Payload,
        triggerEvent: WorkflowTriggerEvent?
    ) async throws -> AuthorizedAudioProcessingClaim.PolicyState {
        do {
            try Self.requireValidLiveAudioProcessingState(payload)
            guard triggerEvent?.workflowID == nil || triggerEvent?.workflowID == payload.workflow.id,
                  WorkflowExecutionPolicy.issue(for: payload.workflow) == nil else {
                throw GateError.audioProcessingAuthorizationInvalid
            }

            return try await revalidateAudioProcessingPolicy(
                payload: payload,
                baseline: EvaluatedPolicy(
                    settings: payload.policySettings,
                    decision: payload.decision,
                    processingDestinations: payload.processingDestinations
                ),
                cloudConfirmationSatisfied: payload.decision.requiresCloudConfirmation
            )
        } catch {
            _ = payload.audioLifetime?.revoke(.authorizationInvalidated)
            throw error
        }
    }

    private func finalizeAudioProcessingPayload(
        _ payload: AuthorizedAudioProcessingLease.Payload,
        policyState: AuthorizedAudioProcessingClaim.PolicyState
    ) async throws -> AuthorizedWorkflowRunContext {
        do {
            try Self.requireValidLiveAudioProcessingState(payload)
            _ = try await revalidateAudioProcessingPolicy(
                payload: payload,
                baseline: EvaluatedPolicy(
                    settings: policyState.settings,
                    decision: policyState.decision,
                    processingDestinations: policyState.processingDestinations
                ),
                cloudConfirmationSatisfied: policyState.cloudConfirmationSatisfied
            )
            try Self.completeLiveAudioProcessingAuthorization(payload)
            return Self.consumedAudioProcessingContext(from: payload)
        } catch {
            _ = payload.audioLifetime?.revoke(.authorizationInvalidated)
            throw error
        }
    }

    private static func requireValidLiveAudioProcessingState(
        _ payload: AuthorizedAudioProcessingLease.Payload
    ) throws {
        guard let liveAuthorizationState = payload.liveAuthorizationState else { return }
        guard liveAuthorizationState.isQueueOwned,
              payload.audioLifetime?.isActive == true else {
            throw GateError.audioProcessingAuthorizationInvalid
        }
    }

    private static func completeLiveAudioProcessingAuthorization(
        _ payload: AuthorizedAudioProcessingLease.Payload
    ) throws {
        guard payload.liveAuthorizationState != nil else { return }
        guard payload.audioLifetime?.complete() == true else {
            throw GateError.audioProcessingAuthorizationInvalid
        }
    }

    private func revalidateAudioProcessingPolicy(
        payload: AuthorizedAudioProcessingLease.Payload,
        baseline: EvaluatedPolicy,
        cloudConfirmationSatisfied: Bool
    ) async throws -> AuthorizedAudioProcessingClaim.PolicyState {
        let currentPolicy = try await evaluatePolicy(
            context: payload.sourcePrivacyContext,
            workflow: payload.workflow
        )
        if currentPolicy.decision.blocksCloudProcessing {
            throw GateError.cloudProcessingBlocked
        }
        guard currentPolicy.processingDestinations == baseline.processingDestinations else {
            throw GateError.policyChangedDuringAuthorization
        }

        if currentPolicy == baseline {
            if currentPolicy.decision.requiresCloudConfirmation,
               !cloudConfirmationSatisfied {
                return try await confirmAudioProcessingPolicy(
                    currentPolicy,
                    payload: payload
                )
            }
            return Self.audioProcessingPolicyState(
                currentPolicy,
                cloudConfirmationSatisfied: cloudConfirmationSatisfied
            )
        }

        let initiallyRequiredConfirmation = baseline.decision.requiresCloudConfirmation
        let currentlyRequiresConfirmation = currentPolicy.decision.requiresCloudConfirmation
        guard Self.settingsAreEquivalentIgnoringCloudConfirmation(
            baseline.settings,
            currentPolicy.settings
        ) else {
            throw GateError.policyChangedDuringAuthorization
        }
        guard Self.policyIsEquivalentIgnoringCloudConfirmation(
            baseline.decision,
            currentPolicy.decision
        ) else {
            throw GateError.policyChangedDuringAuthorization
        }

        if initiallyRequiredConfirmation, !currentlyRequiresConfirmation {
            return Self.audioProcessingPolicyState(
                currentPolicy,
                cloudConfirmationSatisfied: cloudConfirmationSatisfied
            )
        }

        guard !initiallyRequiredConfirmation, currentlyRequiresConfirmation else {
            throw GateError.policyChangedDuringAuthorization
        }
        if cloudConfirmationSatisfied {
            return Self.audioProcessingPolicyState(
                currentPolicy,
                cloudConfirmationSatisfied: true
            )
        }
        return try await confirmAudioProcessingPolicy(
            currentPolicy,
            payload: payload
        )
    }

    private func confirmAudioProcessingPolicy(
        _ currentPolicy: EvaluatedPolicy,
        payload: AuthorizedAudioProcessingLease.Payload
    ) async throws -> AuthorizedAudioProcessingClaim.PolicyState {
        let confirmed = await cloudConfirmationProvider(
            payload.workflow,
            currentPolicy.decision,
            currentPolicy.processingDestinations
        )
        guard confirmed else { throw GateError.cloudConfirmationDeclined }

        let finalPolicy = try await evaluatePolicy(
            context: payload.sourcePrivacyContext,
            workflow: payload.workflow
        )
        guard finalPolicy == currentPolicy else {
            throw GateError.policyChangedDuringAuthorization
        }
        return Self.audioProcessingPolicyState(
            finalPolicy,
            cloudConfirmationSatisfied: true
        )
    }

    private func evaluatePolicy(
        context: ContextSnapshot,
        workflow: WorkflowDefinition,
        invocation: WorkflowRunInvocation = .capture
    ) async throws -> EvaluatedPolicy {
        let settings: PrivacyPolicySettings
        do {
            settings = try await settingsProvider()
        } catch {
            throw GateError.settingsUnavailable
        }

        guard case .classified(let processingDestinations) =
            destinationClassifier(workflow, invocation)
        else {
            throw GateError.processingDestinationUnavailable
        }
        return EvaluatedPolicy(
            settings: settings,
            decision: PrivacyPolicy.evaluate(
                context: context,
                workflow: invocation.usesWorkflowRecognizer ? workflow : nil,
                processingDestinations: processingDestinations,
                settings: settings
            ),
            processingDestinations: processingDestinations
        )
    }

    private static func consumedAudioProcessingContext(
        from payload: AuthorizedAudioProcessingLease.Payload
    ) -> AuthorizedWorkflowRunContext {
        AuthorizedWorkflowRunContext(
            workflow: payload.workflow,
            contextSnapshot: payload.authorizedContext,
            recognitionOptions: payload.recognitionOptions,
            invocation: .capture
        )
    }

    private static func audioProcessingPolicyState(
        _ policy: EvaluatedPolicy,
        cloudConfirmationSatisfied: Bool
    ) -> AuthorizedAudioProcessingClaim.PolicyState {
        AuthorizedAudioProcessingClaim.PolicyState(
            settings: policy.settings,
            decision: policy.decision,
            processingDestinations: policy.processingDestinations,
            cloudConfirmationSatisfied: cloudConfirmationSatisfied
        )
    }

    private static func settingsAreEquivalentIgnoringCloudConfirmation(
        _ lhs: PrivacyPolicySettings,
        _ rhs: PrivacyPolicySettings
    ) -> Bool {
        settingsAreEquivalent(lhs, rhs, ignoringCloudConfirmation: true)
    }

    /// Rule identifiers are persistence identities, not policy inputs. Compare
    /// every policy-relevant field so settings rebuilt on each read remain
    /// stable while any behavioral drift still invalidates authorization.
    private static func settingsAreEquivalent(
        _ lhsSettings: PrivacyPolicySettings,
        _ rhsSettings: PrivacyPolicySettings,
        ignoringCloudConfirmation: Bool = false
    ) -> Bool {
        guard lhsSettings.sensitiveAppRules.count == rhsSettings.sensitiveAppRules.count else {
            return false
        }
        var lhs = lhsSettings
        var rhs = rhsSettings
        for index in rhs.sensitiveAppRules.indices {
            rhs.sensitiveAppRules[index].id = lhs.sensitiveAppRules[index].id
        }
        if ignoringCloudConfirmation {
            lhs.cloudConfirmationRequired = false
            rhs.cloudConfirmationRequired = false
        }
        return lhs == rhs
    }

    private static func policyIsEquivalentIgnoringCloudConfirmation(
        _ lhs: PrivacyPolicyDecision,
        _ rhs: PrivacyPolicyDecision
    ) -> Bool {
        policyWithoutCloudConfirmation(lhs) == policyWithoutCloudConfirmation(rhs)
    }

    private static func policyWithoutCloudConfirmation(
        _ decision: PrivacyPolicyDecision
    ) -> PrivacyPolicyDecision {
        var decision = decision
        decision.decisions.removeAll { $0 == .requireCloudConfirmation }
        if decision.decisions.isEmpty {
            decision.decisions = [.allow]
        }
        decision.reasons.removeAll { $0 == .cloudProviderSelected }
        return decision
    }

    private static func project(_ decision: PrivacyPolicyDecision) -> PrivacyRunEvaluation {
        let status: PrivacyRunEvaluationStatus
        if decision.blocksCloudProcessing {
            status = .blocked
        } else if decision.requiresCloudConfirmation {
            status = .requiresConfirmation
        } else {
            status = .ready
        }

        var reasons = decision.reasons.map(runEvaluationReason)
        if decision.blocksCloudProcessing {
            appendUnique(.cloudProcessingBlocked, to: &reasons)
        }
        if status == .requiresConfirmation {
            appendUnique(.cloudConfirmationRequired, to: &reasons)
        }

        var redactedInputCategories: [PrivacyRedactedInputCategory] = []
        for variable in decision.redactedPromptVariables {
            switch variable {
            case .selected:
                appendUnique(.focusedSelection, to: &redactedInputCategories)
            case .clipboard:
                appendUnique(.clipboardText, to: &redactedInputCategories)
            case .text, .rawText, .app, .bundleID, .group:
                break
            }
        }
        return PrivacyRunEvaluation(
            status: status,
            reasons: reasons,
            redactedInputCategories: redactedInputCategories
        )
    }

    private static func runEvaluationReason(
        _ reason: PrivacyReason
    ) -> PrivacyRunEvaluationReason {
        switch reason {
        case .sensitiveApplication: .sensitiveApplication
        case .secureInput: .secureInput
        case .userDisabledClipboardHistory: .userDisabledClipboardHistory
        case .cloudProviderSelected: .cloudProviderSelected
        case .itemTaggedExcludeFromWorkflowCapture: .itemTaggedExcludeFromWorkflowCapture
        case .unknownFocusContext: .unknownFocusContext
        case .concealedClipboard: .concealedClipboard
        case .transientClipboard: .transientClipboard
        case .autoGeneratedClipboard: .autoGeneratedClipboard
        case .privacySettingsUnavailable: .privacySettingsUnavailable
        }
    }

    private static func appendUnique<T: Equatable>(_ value: T, to values: inout [T]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func representsSameSource(
        _ privacyContext: ContextSnapshot,
        _ fullContext: ContextSnapshot
    ) -> Bool {
        privacyContext.focus.bundleIdentifier == fullContext.focus.bundleIdentifier
            && privacyContext.focus.processIdentifier == fullContext.focus.processIdentifier
            && privacyContext.focus.secureInput == fullContext.focus.secureInput
            && privacyContext.clipboard.changeCount == fullContext.clipboard.changeCount
    }

    private static func hasSamePrivacySourceMetadata(
        _ lhs: ContextSnapshot,
        _ rhs: ContextSnapshot
    ) -> Bool {
        lhs.focus.applicationName == rhs.focus.applicationName
            && lhs.focus.bundleIdentifier == rhs.focus.bundleIdentifier
            && lhs.focus.processIdentifier == rhs.focus.processIdentifier
            && lhs.focus.focusedRole == rhs.focus.focusedRole
            && lhs.focus.selectedText == rhs.focus.selectedText
            && lhs.focus.secureInput == rhs.focus.secureInput
            && lhs.clipboard == rhs.clipboard
    }
}
