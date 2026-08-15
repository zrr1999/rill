import Foundation
import RillCore

public actor SessionCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case running(UUID)
        case resolving(UUID)
        case delivering(UUID)
    }

    public enum SessionError: Error, LocalizedError {
        case alreadyRunning
        case missingRecognizer(String)
        case missingTransformer(PostProcessStepKind)
        case missingAction(String)
        case invalidWorkflowPlan(String)
        case noSpeech
        case unsupportedWorkflow(WorkflowExecutionPolicyIssue)
        case privacyAuthorizationRequired
        case authorizationInvocationMismatch

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "A workflow run is already active."
            case .missingRecognizer(let id):
                return "No speech recognizer is registered for \(id)."
            case .missingTransformer(let kind):
                return "No text transformer is registered for \(kind.rawValue)."
            case .missingAction(let id):
                return "No output action is registered for \(id)."
            case .invalidWorkflowPlan(let message):
                return message
            case .noSpeech:
                return HistoryFailureSanitizer.noSpeechMessage
            case .unsupportedWorkflow(.legacyClipboardAutomationUnsupported):
                return "Legacy clipboard event automation is disabled until production actions and execution receipts are available."
            case .unsupportedWorkflow(.invalidEventType):
                return "The workflow declares an invalid event type."
            case .unsupportedWorkflow(.plannedCapabilityUnavailable):
                return "The workflow is planned but unavailable in this build."
            case .privacyAuthorizationRequired:
                return "The workflow requires a privacy-authorized context before it can run."
            case .authorizationInvocationMismatch:
                return "The privacy authorization no longer matches this workflow invocation."
            }
        }
    }

    private struct RunLaneWaiter {
        let id: UUID
        let runID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var state: State = .idle {
        didSet {
            if case .idle = state {
                grantNextRunLaneWaiterIfPossible()
            }
        }
    }
    private var runLaneOwner: UUID?
    private var runLaneWaiters: [RunLaneWaiter] = []
    private let privacyContextProvider: @Sendable () async -> ContextSnapshot
    private let recognizerRegistry: SpeechRecognizerRegistry
    private let transformerRegistry: TextTransformerRegistry
    private let actionRegistry: OutputActionRegistry
    private let workflowPlanCompiler: WorkflowPlanCompiler
    private let candidateResolver: CandidateResolver
    private let recordStore: RecordStore
    private let recordDeliveryCoordinator: RecordDeliveryCoordinator
    private let recordDeliverySettlementTaskOwner: RecordDeliverySettlementTaskOwner
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let runReceiptRecorder: WorkflowRunReceiptRecorder?
    private let vocabularyCollectionProvider:
        @Sendable () async throws -> [VocabularyCollection]
    private let recognitionOptionsProvider: @Sendable (
        WorkflowDefinition,
        ContextSnapshot
    ) async -> SpeechRecognitionRequestOptions
    private let recognitionTimeoutPolicy: RecognitionTimeoutPolicy
    private let recognitionTimeoutExecutor: RecognitionTimeoutExecutor
    private let defaultRecordDeliveryActionID: String

    private struct RunSession: Sendable {
        let runID: UUID
        let workflow: WorkflowDefinition
        let trigger: WorkflowRunTriggerKind
        let contextSnapshot: ContextSnapshot
        let recognitionOptions: SpeechRecognitionRequestOptions
        let resolvedPlan: ResolvedWorkflowPlan
        let startedAt: Date
        let receiptIsActive: Bool

        var presentation: WorkflowPresentation {
            workflow.presentation
        }
    }

    public init(
        contextProvider _: any ContextProvider,
        privacyContextProvider: @escaping @Sendable () async -> ContextSnapshot = { .empty },
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry,
        candidateResolver: CandidateResolver,
        recordStore: RecordStore = RecordStore(),
        recordDeliveryCoordinator: RecordDeliveryCoordinator? = nil,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        runReceiptRecorder: WorkflowRunReceiptRecorder? = nil,
        vocabularyRuleProvider: @escaping @Sendable () async throws -> [VocabularyRule] = { [] },
        vocabularyCollectionProvider:
            (@Sendable () async throws -> [VocabularyCollection])? = nil,
        recognitionOptionsProvider: @escaping @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions = { _, _ in .empty },
        recognitionTimeoutPolicy: RecognitionTimeoutPolicy = .standard,
        recognitionAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner =
            ManagedTemporaryAudioCleanupOwner(),
        defaultRecordDeliveryActionID: String = "system-clipboard.copy"
    ) {
        self.privacyContextProvider = privacyContextProvider
        self.recognizerRegistry = recognizerRegistry
        self.transformerRegistry = transformerRegistry
        self.actionRegistry = actionRegistry
        self.workflowPlanCompiler = WorkflowPlanCompiler(
            recognizerRegistry: recognizerRegistry,
            transformerRegistry: transformerRegistry,
            actionRegistry: actionRegistry
        )
        self.candidateResolver = candidateResolver
        self.recordStore = recordStore
        let resolvedRecordDeliveryCoordinator =
            recordDeliveryCoordinator ?? RecordDeliveryCoordinator(store: recordStore)
        self.recordDeliveryCoordinator = resolvedRecordDeliveryCoordinator
        self.recordDeliverySettlementTaskOwner = RecordDeliverySettlementTaskOwner(
            deliveryCoordinator: resolvedRecordDeliveryCoordinator
        )
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.runReceiptRecorder = runReceiptRecorder
        self.vocabularyCollectionProvider =
            vocabularyCollectionProvider
            ?? {
                let rules = try await vocabularyRuleProvider()
                return [
                    .personal(entries: rules.map(VocabularyEntry.init(rule:))),
                ]
            }
        self.recognitionOptionsProvider = recognitionOptionsProvider
        self.recognitionTimeoutPolicy = recognitionTimeoutPolicy
        self.recognitionTimeoutExecutor = RecognitionTimeoutExecutor(
            cleanupOwner: recognitionAudioCleanupOwner
        )
        self.defaultRecordDeliveryActionID = defaultRecordDeliveryActionID
    }

    public func currentState() -> State {
        state
    }

    public func shutdownRecordDeliverySettlements() async {
        await recordDeliverySettlementTaskOwner.shutdown()
    }

    /// Reserves the coordinator before any receipt, registry, or provider
    /// suspension. Interactive entry points retain fail-fast busy behavior;
    /// captured audio and recognized wake commands wait FIFO so a new capture
    /// never cancels or discards an older run that is still producing output.
    private func acquireRunLane(
        runID: UUID,
        waitsForAvailability: Bool
    ) async -> Bool {
        if runLaneOwner == nil, case .idle = state {
            runLaneOwner = runID
            state = .running(runID)
            return true
        }
        guard waitsForAvailability else { return false }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                runLaneWaiters.append(
                    RunLaneWaiter(
                        id: waiterID,
                        runID: runID,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancelRunLaneWaiter(id: waiterID) }
        }
    }

    private func cancelRunLaneWaiter(id: UUID) {
        guard let index = runLaneWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = runLaneWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func releaseRunLane(runID: UUID) {
        guard runLaneOwner == runID else { return }
        if state.belongs(to: runID) {
            state = .idle
        }
        runLaneOwner = nil
        grantNextRunLaneWaiterIfPossible()
    }

    private func grantNextRunLaneWaiterIfPossible() {
        guard runLaneOwner == nil,
              case .idle = state,
              !runLaneWaiters.isEmpty else {
            return
        }
        let waiter = runLaneWaiters.removeFirst()
        runLaneOwner = waiter.runID
        state = .running(waiter.runID)
        waiter.continuation.resume(returning: true)
    }
}

private extension SessionCoordinator.State {
    func belongs(to runID: UUID) -> Bool {
        switch self {
        case .idle:
            false
        case .running(let activeRunID), .resolving(let activeRunID),
             .delivering(let activeRunID):
            activeRunID == runID
        }
    }
}

public extension SessionCoordinator {
    func run(
        runID providedRunID: UUID? = nil,
        triggerEvent: WorkflowTriggerEvent? = nil,
        capturedAudio: CapturedAudio? = nil,
        authorizedContext: AuthorizedWorkflowRunContext
    ) async {
        let runID = providedRunID ?? UUID()
        do {
            try await authorizedContext.consume()
        } catch {
            await rejectAuthorizedInvocation(
                runID: runID,
                workflow: authorizedContext.workflow,
                trigger: runReceiptTrigger(for: triggerEvent),
                message: error.localizedDescription
            )
            return
        }
        guard case .capture = authorizedContext.invocation else {
            await rejectAuthorizedInvocation(
                runID: runID,
                workflow: authorizedContext.workflow,
                trigger: runReceiptTrigger(for: triggerEvent)
            )
            return
        }
        await run(
            workflow: authorizedContext.workflow,
            runID: runID,
            triggerEvent: triggerEvent,
            capturedAudio: capturedAudio,
            contextSnapshot: authorizedContext.contextSnapshot,
            recognitionOptions: authorizedContext.recognitionOptions
        )
    }

    /// Continues an authorized voice workflow with command text already
    /// recognized by the local wake-phrase gate. The workflow is compiled for
    /// text input, so recognition is not repeated while vocabulary transforms,
    /// LLM steps, outputs, receipts, and lifecycle events remain unchanged.
    func runRecognizedText(
        _ text: String,
        runID providedRunID: UUID? = nil,
        triggerEvent: WorkflowTriggerEvent? = nil,
        authorizedContext: AuthorizedWorkflowRunContext
    ) async {
        let runID = providedRunID ?? UUID()
        do {
            try await authorizedContext.consume()
        } catch {
            await rejectAuthorizedInvocation(
                runID: runID,
                workflow: authorizedContext.workflow,
                trigger: runReceiptTrigger(for: triggerEvent),
                message: error.localizedDescription
            )
            return
        }
        guard case .capture = authorizedContext.invocation else {
            await rejectAuthorizedInvocation(
                runID: runID,
                workflow: authorizedContext.workflow,
                trigger: runReceiptTrigger(for: triggerEvent)
            )
            return
        }
        _ = await runReportingOutcome(
            workflow: authorizedContext.workflow,
            runID: runID,
            triggerEvent: triggerEvent,
            contextSnapshot: authorizedContext.contextSnapshot,
            recognitionOptions: authorizedContext.recognitionOptions,
            preRecognizedText: text,
            waitsForAvailability: true
        )
    }

    internal func run(
        workflow: WorkflowDefinition,
        runID providedRunID: UUID? = nil,
        triggerEvent: WorkflowTriggerEvent? = nil,
        capturedAudio: CapturedAudio? = nil,
        contextSnapshot: ContextSnapshot? = nil,
        recognitionOptions: SpeechRecognitionRequestOptions? = nil
    ) async {
        _ = await runReportingOutcome(
            workflow: workflow,
            runID: providedRunID,
            triggerEvent: triggerEvent,
            capturedAudio: capturedAudio,
            contextSnapshot: contextSnapshot,
            recognitionOptions: recognitionOptions
        )
    }

    @discardableResult
    internal func runReportingOutcome(
        workflow: WorkflowDefinition,
        runID providedRunID: UUID? = nil,
        triggerEvent: WorkflowTriggerEvent? = nil,
        capturedAudio: CapturedAudio? = nil,
        contextSnapshot: ContextSnapshot? = nil,
        recognitionOptions: SpeechRecognitionRequestOptions? = nil,
        receiptTrigger: WorkflowRunTriggerKind? = nil,
        preRecognizedText: String? = nil,
        waitsForAvailability: Bool = false
    ) async -> WorkflowRunExecutionResult {
        let runID = providedRunID ?? UUID()
        let effectiveReceiptTrigger = receiptTrigger ?? runReceiptTrigger(for: triggerEvent)
        let acquiredRunLane = await acquireRunLane(
            runID: runID,
            waitsForAvailability: waitsForAvailability
        )
        guard acquiredRunLane else {
            if waitsForAvailability, Task.isCancelled {
                return .failed(
                    WorkflowRunFailureSummary(
                        runID: runID,
                        stage: .preparing,
                        code: .cancelled
                    )
                )
            }
            let busyReceiptRegistration = await beginRunReceipt(
                runID: runID,
                workflowID: workflow.id,
                trigger: effectiveReceiptTrigger
            )
            let busyReceiptIsActive = busyReceiptRegistration == .active
            if busyReceiptRegistration != .duplicate {
                await finishRunReceipt(
                    runID: runID,
                    isActive: busyReceiptIsActive,
                    termination: .skipped(reason: .busy)
                )
            }
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .busy
                )
            )
        }
        defer { releaseRunLane(runID: runID) }

        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: effectiveReceiptTrigger
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .busy
                )
            )
        }
        let receiptIsActive = receiptRegistration == .active

        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            let error = SessionError.unsupportedWorkflow(issue)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .unsupported)
            )
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: error.localizedDescription
            )
            return .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .configuration
                )
            )
        }

        guard let contextSnapshot else {
            let error = SessionError.privacyAuthorizationRequired
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .preparing, code: .configuration)
            )
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: error.localizedDescription
            )
            return .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: .preparing,
                    code: .configuration
                )
            )
        }

        var failureStage = WorkflowRunStage.preparing
        do {
            let session = try await startRunSession(
                for: workflow,
                runID: runID,
                trigger: effectiveReceiptTrigger,
                contextSnapshot: contextSnapshot,
                recognitionOptions: recognitionOptions,
                compilationInput: preRecognizedText == nil ? nil : .text,
                receiptIsActive: receiptIsActive
            )
            failureStage = .recognizing
            let recognition: RecognitionResult
            if let preRecognizedText {
                let text = preRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw SessionError.noSpeech
                }
                recognition = RecognitionResult(
                    rawText: text,
                    bestText: text,
                    candidateSets: []
                )
                await eventBus.publish(.recognitionCompleted(recognition))
            } else {
                recognition = try await recognize(
                    in: session,
                    triggerEvent: triggerEvent,
                    capturedAudio: capturedAudio
                )
            }
            failureStage = .resolving
            let resolvedRecognition = await resolveIfNeeded(recognition, in: session)
            failureStage = .transforming
            let transformation = try await transformText(
                from: resolvedRecognition,
                in: session,
                allowsSpeechTextFallback:
                    (capturedAudio != nil || preRecognizedText != nil)
                    && workflow.speechMode != .voiceAssistant
            )
            let finalText = transformation.finalText
            let correctionSource = RecognitionCorrectionSource(
                preMappingText: resolvedRecognition.bestText,
                context: vocabularyContext(in: session),
                languageModelInputTexts:
                    transformation.languageModelInputTexts.isEmpty
                    ? nil
                    : transformation.languageModelInputTexts,
                languageModelTraces:
                    transformation.languageModelTraces.isEmpty
                    ? nil
                    : transformation.languageModelTraces
            )
            failureStage = .delivering
            let deliverySummary = try await deliver(
                finalText: finalText,
                recognition: resolvedRecognition,
                in: session
            )
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: deliverySummary.terminalReceipt
            )
            let summary = await complete(
                session: session,
                finalText: finalText,
                correctionSource: correctionSource
            )
            return .completed(summary)
        } catch {
            let failedWorkflow = workflow.presentation
            if let cancellation = workflowRunCancellationSummary(
                for: error,
                runID: runID,
                stage: failureStage
            ) {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: cancellation.termination
                )
                await publishCancellation(cancellation)
                state = .idle
                return .cancelled(cancellation)
            }
            let code = workflowRunFailureCode(for: error)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: terminalReceiptForFailure(
                    error,
                    stage: failureStage,
                    code: code
                )
            )
            await recordStage(.failed, runID: runID, workflow: failedWorkflow)
            await publishFailure(runID: runID, workflow: failedWorkflow, message: error.localizedDescription)
            state = .idle
            return .failed(
                WorkflowRunFailureSummary(
                    runID: runID,
                    stage: failureStage,
                    code: code
                )
            )
        }
    }

    private func workflowRunFailureCode(for error: Error) -> WorkflowRunFailureCode {
        if error is CancellationError {
            return .cancelled
        }
        if let deadlineError = error as? RecognitionDeadlineError {
            switch deadlineError {
            case .timedOut:
                return .processing
            case .previousOperationStillFinishing:
                return .busy
            }
        }
        guard let sessionError = error as? SessionError else {
            return .processing
        }
        switch sessionError {
        case .alreadyRunning:
            return .busy
        case .noSpeech:
            return .noSpeech
        case .missingRecognizer, .missingTransformer, .missingAction, .invalidWorkflowPlan,
             .unsupportedWorkflow,
             .privacyAuthorizationRequired, .authorizationInvocationMismatch:
            return .configuration
        }
    }

    func deliverNextRecord(actionID: String? = nil) async {
        await deliverNextRecord(for: FocusedApplicationIdentity(), actionID: actionID)
    }

    func deliverNextRecord(
        for targetApplication: FocusedApplicationIdentity,
        actionID: String? = nil
    ) async {
        await deliverRecord(
            for: targetApplication,
            actionID: actionID,
            exactSubject: nil,
            expectedTarget: nil
        )
    }

    func deliverRecord(
        matching subject: RecordDeliverySubject,
        to target: FocusedApplicationTargetIdentity,
        actionID: String? = nil
    ) async {
        await deliverRecord(
            for: FocusedApplicationIdentity(bundleIdentifier: target.bundleIdentifier),
            actionID: actionID,
            exactSubject: subject,
            expectedTarget: target
        )
    }

    private func deliverRecord(
        for targetApplication: FocusedApplicationIdentity,
        actionID: String?,
        exactSubject: RecordDeliverySubject?,
        expectedTarget: FocusedApplicationTargetIdentity?
    ) async {
        var selectedActionID = actionID ?? defaultRecordDeliveryActionID
        var workflow = WorkflowDefinition(
            name: "Record Delivery",
            titleKey: .recordDelivery,
            plan: WorkflowPlan(
                setup: WorkflowSetupPhase(),
                process: WorkflowProcessPhase(),
                output: WorkflowOutputPhase(
                    actions: [OutputActionReference(id: selectedActionID)]
                )
            ),
            ui: WorkflowUIConfig(
                symbolName: WorkflowUISymbol.squareStack3dUpFill.rawValue,
                accentColorName: "indigo"
            )
        )
        let recordDeliveryWorkflow = workflow.presentation
        let runID = UUID()
        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: .recordDelivery
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: recordDeliveryWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }
        let receiptIsActive = receiptRegistration == .active

        guard case .idle = state else {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .busy)
            )
            await publishFailure(
                runID: runID,
                workflow: recordDeliveryWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }

        state = .delivering(runID)
        defer { state = .idle }

        let preparation: RecordDeliveryCoordinator.Preparation
        do {
            if let exactSubject {
                let sink = Self.sinkIdentity(for: selectedActionID) ?? .focusedApplication
                let lease = try await recordDeliveryCoordinator.beginDelivery(
                    matching: exactSubject,
                    sink: sink
                )
                preparation = .init(lease: lease, route: nil)
            } else {
                preparation = try await recordDeliveryCoordinator.beginDelivery(
                    to: targetApplication,
                    requestedSink: Self.sinkIdentity(for: selectedActionID)
                )
            }
        } catch let error as RecordStoreError
        where error == .membershipUnavailable || error == .manualSelectionRequired {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .recordMissing)
            )
            return
        } catch {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .delivering, code: .processing)
            )
            await publishFailure(
                runID: runID,
                workflow: recordDeliveryWorkflow,
                message: HistoryFailureSanitizer.genericMessage
            )
            return
        }
        let route = preparation.route
        if let route {
            selectedActionID = Self.actionID(for: route.sink)
            workflow.plan.output.actions = [OutputActionReference(id: selectedActionID)]
        }
        let deliverySink = preparation.sink
        let lease = preparation.lease
        let recordText = lease.record.payload.textValue ?? ""
        if deliverySink == .recordCollection {
            guard let collectionID = route?.sinkCollectionID else {
                try? await recordDeliveryCoordinator.failDelivery(lease.id)
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .failed(stage: .delivering, code: .configuration)
                )
                return
            }
            await recordStage(.delivering, runID: runID, workflow: recordDeliveryWorkflow)
            do {
                if receiptIsActive, let runReceiptRecorder {
                    try await runReceiptRecorder.beginAction(runID: runID, actionIndex: 0)
                }
                _ = try await recordStore.addMembership(
                    recordID: lease.record.id,
                    to: collectionID
                )
                await finishRecordedAction(
                    runID: runID,
                    actionIndex: 0,
                    result: .storedRecord,
                    receiptIsActive: receiptIsActive
                )
                await eventBus.publish(.actionExecuted(actionID: selectedActionID, result: .storedRecord))
                await recordAction(
                    runID: runID,
                    workflow: workflow.presentation,
                    actionID: selectedActionID,
                    result: .storedRecord
                )
                _ = try await recordDeliveryCoordinator.completeDelivery(lease.id)
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .completed
                )
                await eventBus.publish(
                    .runCompleted(
                        WorkflowRunSummary(
                            runID: runID,
                            workflowID: workflow.id,
                            workflow: workflow.presentation,
                            trigger: .recordDelivery,
                            finalText: recordText
                        )
                    )
                )
                await recordStage(.completed, runID: runID, workflow: workflow.presentation)
            } catch {
                await finishRecordedAction(
                    runID: runID,
                    actionIndex: 0,
                    result: .failed,
                    receiptIsActive: receiptIsActive
                )
                try? await recordDeliveryCoordinator.failDelivery(lease.id)
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .failed(stage: .delivering, code: .processing)
                )
                await recordStage(.failed, runID: runID, workflow: workflow.presentation)
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: error.localizedDescription
                )
            }
            return
        }
        state = .delivering(runID)
        await recordStage(.delivering, runID: runID, workflow: recordDeliveryWorkflow)

        guard let action = actionRegistry.action(for: selectedActionID) else {
            try? await recordDeliveryCoordinator.failDelivery(lease.id)
            await recordStage(.failed, runID: runID, workflow: recordDeliveryWorkflow)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .delivering, code: .configuration)
            )
            await publishFailure(
                runID: runID,
                workflow: recordDeliveryWorkflow,
                message: SessionError.missingAction(selectedActionID).localizedDescription
            )
            state = .idle
            return
        }

        let context = await privacyContextProvider()
        if let expectedTarget, !expectedTarget.matches(context.focus) {
            try? await recordDeliveryCoordinator.failDelivery(lease.id)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .delivering, code: .processing)
            )
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: HistoryFailureSanitizer.genericMessage
            )
            return
        }
        let actionContext = ActionContext(
            runID: runID,
            workflow: workflow,
            contextSnapshot: context,
            recognitionResult: RecognitionResult(rawText: recordText, bestText: recordText),
            finalText: recordText,
            startedAt: lease.record.createdAt,
            finishedAt: Date()
        )

        do {
            let deliverySummary: DeliveryExecutionSummary
            var committedOutputFailure: CommittedOutputFailure?
            do {
                let result = try await executeRecordedAction(
                    action,
                    actionID: selectedActionID,
                    actionIndex: 0,
                    text: recordText,
                    recordDraft: RecordDraft(
                        payload: lease.record.payload,
                        provenance: lease.record.provenance,
                        createdAt: lease.record.createdAt
                    ),
                    context: actionContext,
                    runID: runID,
                    workflow: workflow.presentation,
                    receiptIsActive: receiptIsActive
                )
                switch result {
                case .injected, .copiedToClipboard, .storedRecord, .externalOutput:
                    deliverySummary = DeliveryExecutionSummary(successfulActionCount: 1)
                case .skipped:
                    deliverySummary = DeliveryExecutionSummary(skippedActionCount: 1)
                case .failed(let message):
                    throw OutputActionExecutionFailure(
                        message: message,
                        successfulActionCount: 0
                    )
                }
            } catch let failure as CommittedOutputFailure {
                // The irreversible action completed even though its local
                // recovery work did not. Settle the Record as delivered and
                // preserve a fixed do-not-repeat failure for the user.
                deliverySummary = DeliveryExecutionSummary(successfulActionCount: 1)
                committedOutputFailure = failure
            }
            do {
                _ = try await recordDeliveryCoordinator.completeDelivery(lease.id)
            } catch where deliverySummary.successfulActionCount > 0 {
                await recordDeliverySettlementTaskOwner.schedule(leaseID: lease.id)
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .partiallyCompleted(code: .processing)
                )
                await recordStage(.failed, runID: runID, workflow: workflow.presentation)
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: committedOutputFailure?.message
                        ?? Self.committedOutputSettlementMessage
                )
                return
            } catch {
                throw error
            }
            if let committedOutputFailure {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .partiallyCompleted(code: .processing)
                )
                await recordStage(.failed, runID: runID, workflow: workflow.presentation)
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: committedOutputFailure.message
                )
                return
            }
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: deliverySummary.terminalReceipt
            )
            await eventBus.publish(
                .runCompleted(
                    WorkflowRunSummary(
                        runID: runID,
                        workflowID: workflow.id,
                        workflow: workflow.presentation,
                        trigger: .recordDelivery,
                        finalText: recordText
                    )
                )
            )
            await recordStage(.completed, runID: runID, workflow: workflow.presentation)
            state = .idle
        } catch {
            if let cancellation = workflowRunCancellationSummary(
                for: error,
                runID: runID,
                stage: .delivering
            ) {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: cancellation.termination
                )
                try? await recordDeliveryCoordinator.cancelDelivery(lease.id)
                await publishCancellation(cancellation)
                return
            }
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: terminalReceiptForFailure(
                    error,
                    stage: .delivering,
                    code: .processing
                )
            )
            try? await recordDeliveryCoordinator.failDelivery(lease.id)
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
            state = .idle
        }
    }

}

private extension SessionCoordinator {
    static let committedOutputSettlementMessage =
        "The output may already have been delivered. Rill is retrying local bookkeeping; do not repeat this action."

    static func actionID(for sink: RecordSinkIdentity) -> String {
        switch sink {
        case .focusedApplication: RecordActionID.focusedApplicationInsert
        case .systemClipboard: RecordActionID.systemClipboardCopy
        case .recordCollection: RecordActionID.collectionRoute
        }
    }

    static func sinkIdentity(for actionID: String) -> RecordSinkIdentity? {
        switch actionID {
        case RecordActionID.focusedApplicationInsert: .focusedApplication
        case RecordActionID.systemClipboardCopy: .systemClipboard
        case RecordActionID.collectionRoute: .recordCollection
        default: nil
        }
    }

    func rejectAuthorizedInvocation(
        runID: UUID,
        workflow: WorkflowDefinition,
        trigger: WorkflowRunTriggerKind,
        message: String = SessionError.authorizationInvocationMismatch.localizedDescription
    ) async {
        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: trigger
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }
        await finishRunReceipt(
            runID: runID,
            isActive: receiptRegistration == .active,
            termination: .skipped(reason: .privacyBlocked)
        )
        await publishFailure(
            runID: runID,
            workflow: workflow.presentation,
            message: message
        )
    }

    func runReceiptTrigger(
        for triggerEvent: WorkflowTriggerEvent?
    ) -> WorkflowRunTriggerKind {
        guard let triggerEvent else { return .manual }
        switch triggerEvent.binding {
        case .manual:
            return .manual
        case .menuBar:
            return .menuBar
        case .hotkey:
            return .hotkey
        case .wakeWord:
            return .wakeWord
        }
    }

    func beginRunReceipt(
        runID: UUID,
        workflowID: UUID?,
        trigger: WorkflowRunTriggerKind
    ) async -> RunReceiptRegistration {
        guard let runReceiptRecorder else { return .inactive }
        do {
            try await runReceiptRecorder.begin(
                runID: runID,
                workflowID: workflowID,
                trigger: trigger
            )
            return .active
        } catch let error as WorkflowRunReceiptRecorderError {
            switch error {
            case .runAlreadyStarted, .terminalAlreadyFinalized:
                await recordRunReceiptCoordinationFailure(
                    runID: runID,
                    reason: "duplicate-run-id"
                )
                return .duplicate
            case .persistenceFailed:
                // The recorder already emitted a safe persistence diagnostic.
                // Receipt storage availability must not redefine execution.
                return .inactive
            default:
                await recordRunReceiptCoordinationFailure(
                    runID: runID,
                    reason: "begin-failed"
                )
                return .inactive
            }
        } catch {
            await recordRunReceiptCoordinationFailure(
                runID: runID,
                reason: "begin-failed"
            )
            return .inactive
        }
    }

    func finishRunReceipt(
        runID: UUID,
        isActive: Bool,
        termination: WorkflowRunTermination
    ) async {
        guard isActive, let runReceiptRecorder else { return }
        do {
            _ = try await runReceiptRecorder.finish(
                runID: runID,
                termination: termination
            )
        } catch let error as WorkflowRunReceiptRecorderError {
            if case .writeObsoletedByClearBarrier = error {
                // The user already cleared this terminal timestamp. Execution
                // remains authoritative, but no receipt event may be published.
                return
            }
            guard case .persistenceFailed = error else {
                await recordRunReceiptCoordinationFailure(
                    runID: runID,
                    reason: "finish-failed"
                )
                return
            }
            // Persistence failure was already recorded by the recorder. The
            // runCompleted/runFailed lifecycle still reflects actual execution.
        } catch {
            await recordRunReceiptCoordinationFailure(
                runID: runID,
                reason: "finish-failed"
            )
        }
    }

    func terminalReceiptForFailure(
        _ error: any Error,
        stage: WorkflowRunStage,
        code: WorkflowRunFailureCode
    ) -> WorkflowRunTermination {
        if let actionFailure = error as? OutputActionExecutionFailure,
           actionFailure.successfulActionCount > 0 {
            return .partiallyCompleted(code: .processing)
        }
        if code == .cancelled {
            return .cancelled(stage: stage)
        }
        return .failed(stage: stage, code: code)
    }

    func workflowRunCancellationSummary(
        for error: any Error,
        runID: UUID,
        stage: WorkflowRunStage
    ) -> WorkflowRunCancelledSummary? {
        if let actionCancellation = error as? OutputActionCancellation {
            return WorkflowRunCancelledSummary(
                runID: runID,
                stage: stage,
                wasPartiallyCompleted: actionCancellation.successfulActionCount > 0
            )
        }
        guard error is CancellationError else { return nil }
        return WorkflowRunCancelledSummary(
            runID: runID,
            stage: stage,
            wasPartiallyCompleted: false
        )
    }

    func executeRecordedAction(
        _ action: any OutputAction,
        actionID: String,
        actionIndex: Int,
        text: String,
        recordDraft: RecordDraft? = nil,
        context: ActionContext,
        runID: UUID,
        workflow: WorkflowPresentation,
        receiptIsActive: Bool
    ) async throws -> ActionResult {
        try Task.checkCancellation()
        if receiptIsActive, let runReceiptRecorder {
            do {
                try await runReceiptRecorder.beginAction(
                    runID: runID,
                    actionIndex: actionIndex
                )
            } catch {
                await recordRunReceiptCoordinationFailure(
                    runID: runID,
                    reason: "action-begin-failed"
                )
                throw RunReceiptActionPreparationFailure()
            }
        }

        let result: ActionResult
        do {
            try Task.checkCancellation()
            let record = recordDraft ?? RecordDraft(
                payload: .text(text),
                provenance: RecordProvenance(
                    source: RecordSourceIdentity(kind: .workflow),
                    sourceApplicationName: context.contextSnapshot.focus.applicationName,
                    sourceBundleIdentifier: context.contextSnapshot.focus.bundleIdentifier,
                    workflowID: context.workflow.id,
                    workflowRunID: context.runID,
                    workflow: context.workflow.presentation,
                    captureTags: context.workflow.excludesOutputFromRecordCapture
                        ? [.excludeFromWorkflowCapture]
                        : [],
                    alternatives: context.recognitionResult.candidateSets.flatMap { set in
                        set.candidates.map(\.text)
                    }
                ),
                createdAt: context.finishedAt
            )
            result = try await action.execute(record: record, context: context)
        } catch let failure as CommittedOutputFailure {
            let result = ActionResult.injected
            await finishRecordedAction(
                runID: runID,
                actionIndex: actionIndex,
                result: WorkflowActionResultCode(result),
                receiptIsActive: receiptIsActive
            )
            await eventBus.publish(.actionExecuted(actionID: actionID, result: result))
            await recordAction(
                runID: runID,
                workflow: workflow,
                actionID: actionID,
                result: result
            )
            throw failure
        } catch is CancellationError {
            await finishRecordedAction(
                runID: runID,
                actionIndex: actionIndex,
                result: .cancelled,
                receiptIsActive: receiptIsActive
            )
            throw CancellationError()
        } catch {
            await finishRecordedAction(
                runID: runID,
                actionIndex: actionIndex,
                result: .failed,
                receiptIsActive: receiptIsActive
            )
            await recordAction(
                runID: runID,
                workflow: workflow,
                actionID: actionID,
                result: .failed("")
            )
            throw error
        }

        await finishRecordedAction(
            runID: runID,
            actionIndex: actionIndex,
            result: WorkflowActionResultCode(result),
            receiptIsActive: receiptIsActive
        )
        await eventBus.publish(.actionExecuted(actionID: actionID, result: result))
        await recordAction(
            runID: runID,
            workflow: workflow,
            actionID: actionID,
            result: result
        )
        return result
    }

    func finishRecordedAction(
        runID: UUID,
        actionIndex: Int,
        result: WorkflowActionResultCode,
        receiptIsActive: Bool
    ) async {
        guard receiptIsActive, let runReceiptRecorder else { return }
        do {
            try await runReceiptRecorder.finishAction(
                runID: runID,
                actionIndex: actionIndex,
                result: result
            )
        } catch {
            await recordRunReceiptCoordinationFailure(
                runID: runID,
                reason: "action-finish-failed"
            )
        }
    }

    func recordRunReceiptCoordinationFailure(
        runID: UUID,
        reason: String
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .error,
                event: "run-receipt.coordination.failed",
                message: "Run receipt coordination failed.",
                metadata: ["reason": reason]
            )
        )
    }

    func publishFailure(runID: UUID?, workflow: WorkflowPresentation?, message: String) async {
        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    runID: runID,
                    subsystem: .session,
                    level: .error,
                    event: "session.failure",
                    message: message
                )
            )
        }
        await eventBus.publish(.runFailed(runID: runID, workflow: workflow, message: message))
    }

    func publishCancellation(_ summary: WorkflowRunCancelledSummary) async {
        if let diagnostics {
            await diagnostics.record(
                DiagnosticEvent(
                    runID: summary.runID,
                    subsystem: .session,
                    level: .info,
                    event: "session.cancelled",
                    message: "Workflow run was cancelled.",
                    metadata: [
                        "outcome": summary.wasPartiallyCompleted ? "partial" : "cancelled",
                        "stage": summary.stage.rawValue,
                    ]
                )
            )
        }
        await eventBus.publish(.runCancelled(summary))
    }

    private func recordStage(
        _ stage: WorkflowRunStage,
        runID: UUID,
        workflow: WorkflowPresentation,
        metadata: [String: String] = [:]
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .debug,
                event: "session.stage",
                message: "Workflow entered the \(stage.rawValue) stage.",
                metadata: [
                    "stage": stage.rawValue,
                    "workflow": workflow.fallbackName,
                ].merging(metadata) { _, new in new }
            )
        )
    }

    private func recordTransformStep(
        runID: UUID,
        workflow: WorkflowPresentation,
        step: PostProcessStep,
        transformerID: String
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .debug,
                event: "session.transform.step",
                message: "Applied post-process step \(step.kind.rawValue).",
                metadata: [
                    "workflow": workflow.fallbackName,
                    "stepID": step.id.uuidString,
                    "stepKind": step.kind.rawValue,
                    "transformerID": transformerID,
                ]
            )
        )
    }

    private func recordAction(
        runID: UUID,
        workflow: WorkflowPresentation,
        actionID: String,
        result: ActionResult
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .debug,
                event: "session.action",
                message: "Executed output action \(actionID).",
                metadata: [
                    "workflow": workflow.fallbackName,
                    "actionID": actionID,
                    "resultCode": diagnosticResultCode(for: result),
                ]
            )
        )
    }

    private func diagnosticResultCode(for result: ActionResult) -> String {
        switch result {
        case .injected:
            return "injected"
        case .copiedToClipboard:
            return "copiedToClipboard"
        case .storedRecord:
            return "storedRecord"
        case .externalOutput:
            return "externalOutput"
        case .skipped:
            return "skipped"
        case .failed:
            return "failed"
        }
    }

    private func startRunSession(
        for workflow: WorkflowDefinition,
        runID: UUID,
        trigger: WorkflowRunTriggerKind,
        contextSnapshot: ContextSnapshot,
        recognitionOptions providedRecognitionOptions: SpeechRecognitionRequestOptions? = nil,
        compilationInput: WorkflowPlanInput? = nil,
        receiptIsActive: Bool
    ) async throws -> RunSession {
        let startedAt = Date()
        state = .running(runID)
        await eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    trigger: trigger,
                    startedAt: startedAt
                )
            )
        )
        await recordStage(
            .preparing,
            runID: runID,
            workflow: workflow.presentation,
            metadata: [
                "workflowID": workflow.id.uuidString,
                "trigger": workflow.trigger.rawValue
            ]
        )

        await eventBus.publish(.contextCaptured(contextSnapshot))
        var recognitionOptions: SpeechRecognitionRequestOptions
        if let providedRecognitionOptions {
            recognitionOptions = providedRecognitionOptions
        } else {
            recognitionOptions = await recognitionOptionsProvider(workflow, contextSnapshot)
        }
        let vocabularyContext = VocabularyRuleContext(
            contextSnapshot: contextSnapshot,
            recordCollectionID: workflow.legacyTargetRecordCollectionID,
            locale: recognitionOptions.language
                ?? workflow.plan.setup.speechRoute?.language
                ?? workflow.metadata[WorkflowMetadataKey.languageOverride]
        )
        let collections: [VocabularyCollection]
        if workflow.plan.setup.vocabularyBindings.isEmpty {
            collections = []
        } else {
            do {
                collections = try await vocabularyCollectionProvider()
            } catch {
                throw SessionError.invalidWorkflowPlan(
                    "Vocabulary collections are unavailable."
                )
            }
        }
        let resolvedPlan: ResolvedWorkflowPlan
        do {
            resolvedPlan = try workflowPlanCompiler.compile(
                workflow: workflow,
                collections: collections,
                context: vocabularyContext,
                input: compilationInput,
                allowEmptyOutput: trigger == .failedAudioRecovery
            )
        } catch {
            throw SessionError.invalidWorkflowPlan(error.localizedDescription)
        }
        recognitionOptions.hints = resolvedPlan.recognitionHints
        await recordCompiledPlan(resolvedPlan, runID: runID, workflow: workflow.presentation)
        return RunSession(
            runID: runID,
            workflow: workflow,
            trigger: trigger,
            contextSnapshot: contextSnapshot,
            recognitionOptions: recognitionOptions,
            resolvedPlan: resolvedPlan,
            startedAt: startedAt,
            receiptIsActive: receiptIsActive
        )
    }

    private func recognize(
        in session: RunSession,
        triggerEvent: WorkflowTriggerEvent?,
        capturedAudio: CapturedAudio?
    ) async throws -> RecognitionResult {
        guard
            let recognizerID = session.resolvedPlan.recognizerID,
            let recognizer = recognizerRegistry.recognizer(for: recognizerID)
        else {
            throw SessionError.missingRecognizer(
                session.resolvedPlan.recognizerID ?? "none"
            )
        }

        await recordStage(
            .recognizing,
            runID: session.runID,
            workflow: session.presentation,
            metadata: ["recognizerID": recognizerID]
        )
        var options = session.recognitionOptions
        if !recognizer.capabilities.supports(.keyterm),
           session.resolvedPlan.validHotwordCount > 0
        {
            await recordUnsupportedRecognitionHints(
                count: session.resolvedPlan.validHotwordCount,
                recognizerID: recognizer.id,
                session: session
            )
            options.hints = .empty
        }
        let request = RecognitionRequest(
            runID: session.runID,
            workflow: session.workflow,
            contextSnapshot: session.contextSnapshot,
            triggerEvent: triggerEvent,
            capturedAudio: capturedAudio,
            options: options
        )
        let timeoutSeconds = recognitionTimeoutPolicy.timeoutSeconds(
            forAudioDuration: capturedAudio?.durationSeconds
        )
        let recognition: RecognitionResult
        do {
            recognition = try await recognitionTimeoutExecutor.recognize(
                using: recognizer,
                request: request,
                timeout: .seconds(timeoutSeconds)
            )
        } catch let error as RecognitionDeadlineError {
            await recordRecognitionDeadlineFailure(
                error,
                recognizerID: recognizer.id,
                session: session
            )
            throw error
        }
        try Task.checkCancellation()
        guard !recognition.bestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError.noSpeech
        }
        await eventBus.publish(.recognitionCompleted(recognition))
        return recognition
    }

    private func recordRecognitionDeadlineFailure(
        _ error: RecognitionDeadlineError,
        recognizerID: String,
        session: RunSession
    ) async {
        guard let diagnostics else { return }
        let event: String
        let message: String
        let metadata = ["recognizerID": recognizerID]
        switch error {
        case .timedOut:
            event = "session.recognition.timeout"
            message = "Speech recognition exceeded its runtime deadline."
        case .previousOperationStillFinishing:
            event = "session.recognition.recovery-pending"
            message = "The recognizer is still retiring a previous operation."
        }
        await diagnostics.record(
            DiagnosticEvent(
                runID: session.runID,
                subsystem: .session,
                level: .error,
                event: event,
                message: message,
                metadata: metadata
            )
        )
    }

    private func resolveIfNeeded(_ recognition: RecognitionResult, in session: RunSession) async -> RecognitionResult {
        guard
            let resolutionStep = session.resolvedPlan.declaration.process.steps.first(
                where: { $0.kind == .resolveUncertainty }
            ),
            let uncertaintyPolicy = resolutionStep.uncertaintyPolicy,
            uncertaintyPolicy.mode != .off,
            recognition.requiresResolution
        else {
            return recognition
        }

        state = .resolving(session.runID)
        await recordStage(
            .resolving,
            runID: session.runID,
            workflow: session.presentation,
            metadata: ["candidateSetCount": String(recognition.candidateSets.count)]
        )
        let resolutionCase = CandidateResolutionCase(
            runID: session.runID,
            recognitionResult: recognition,
            policy: uncertaintyPolicy
        )
        let outcome = await candidateResolver.resolve(resolutionCase)
        await eventBus.publish(
            .candidateResolutionFinished(caseID: resolutionCase.id, resolvedText: outcome.result.bestText)
        )
        return outcome.result
    }

    private func transformText(
        from recognition: RecognitionResult,
        in session: RunSession,
        allowsSpeechTextFallback: Bool = false
    ) async throws -> TextTransformationResult {
        var finalText = recognition.bestText
        var languageModelInputTexts: [String] = []
        var languageModelTraces: [LanguageModelTrace] = []
        var didRecordTransformStage = false
        for processStep in session.resolvedPlan.declaration.process.steps {
            switch processStep.kind {
            case .recognizeSpeech, .resolveUncertainty:
                continue
            case .applyVocabulary:
                let result = VocabularyRuleApplicator.apply(
                    text: finalText,
                    rules: session.resolvedPlan.replacementRules
                )
                finalText = result.text
                if result.changed || !result.issues.isEmpty {
                    if !didRecordTransformStage {
                        await recordStage(
                            .transforming,
                            runID: session.runID,
                            workflow: session.presentation,
                            metadata: [
                                "stepCount": String(
                                    session.resolvedPlan.declaration.process.steps.count
                                ),
                                "vocabularyApplicationCount": String(result.applications.count),
                                "vocabularyIssueCount": String(result.issues.count),
                            ]
                        )
                        didRecordTransformStage = true
                    }
                    await recordVocabularyApplication(result, in: session)
                }
                continue
            case .snippetReplacement, .llmRewrite, .llmAnswer, .normalizeWhitespace:
                break
            }
            guard let step = processStep.postProcessStep else { continue }
            if !didRecordTransformStage {
                await recordStage(
                    .transforming,
                    runID: session.runID,
                    workflow: session.presentation,
                    metadata: [
                        "stepCount": String(
                            session.resolvedPlan.declaration.process.steps.count
                        ),
                    ]
                )
                didRecordTransformStage = true
            }
            guard let transformer = transformerRegistry.transformer(for: step.kind) else {
                throw SessionError.missingTransformer(step.kind)
            }
            if step.kind == .llmRewrite || step.kind == .llmAnswer {
                languageModelInputTexts.append(finalText)
            }
            do {
                let context = TransformContext(
                    runID: session.runID,
                    workflow: session.workflow,
                    contextSnapshot: session.contextSnapshot,
                    recognitionResult: recognition
                )
                if let tracedTransformer = transformer as? any TracedTextTransformer,
                   step.kind == .llmRewrite || step.kind == .llmAnswer {
                    let result = try await tracedTransformer.transformWithTrace(
                        text: finalText,
                        step: step,
                        context: context
                    )
                    finalText = result.text
                    languageModelTraces.append(result.trace)
                } else {
                    finalText = try await transformer.transform(
                        text: finalText,
                        step: step,
                        context: context
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as any SpeechTextFallbackEligibleError
                where allowsSpeechTextFallback
                    && step.kind == .llmRewrite
                    && error.allowsSpeechTextFallback
            {
                await recordSpeechTextTransformFallback(
                    runID: session.runID,
                    workflow: session.presentation,
                    step: step,
                    transformerID: transformer.id
                )
                continue
            }
            try Task.checkCancellation()
            await eventBus.publish(.transformationApplied(stepID: step.id, text: finalText))
            await recordTransformStep(
                runID: session.runID,
                workflow: session.presentation,
                step: step,
                transformerID: transformer.id
            )
        }

        return TextTransformationResult(
            finalText: finalText,
            languageModelInputTexts: languageModelInputTexts,
            languageModelTraces: languageModelTraces
        )
    }

    private func recordSpeechTextTransformFallback(
        runID: UUID,
        workflow: WorkflowPresentation,
        step: PostProcessStep,
        transformerID: String
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .warning,
                event: "session.transform.fallback",
                message: "A recoverable speech-text transform failed; recognized text was retained.",
                metadata: [
                    "workflow": workflow.fallbackName,
                    "stepKind": step.kind.rawValue,
                    "transformerID": transformerID,
                    "outcome": "preserved",
                    "reason": "request-failed",
                ]
            )
        )
    }

    private func vocabularyContext(in session: RunSession) -> VocabularyRuleContext {
        VocabularyRuleContext(
            contextSnapshot: session.contextSnapshot,
            recordCollectionID: session.workflow.legacyTargetRecordCollectionID,
            locale: session.recognitionOptions.language
                ?? session.workflow.metadata[WorkflowMetadataKey.languageOverride]
        )
    }

    private func recordVocabularyApplication(
        _ result: VocabularyApplicationResult,
        in session: RunSession
    ) async {
        guard let diagnostics else { return }
        let replacementCount = result.applications.reduce(0) { $0 + $1.matchCount }
        await diagnostics.record(
            DiagnosticEvent(
                runID: session.runID,
                subsystem: .session,
                level: result.issues.isEmpty ? .debug : .warning,
                event: "session.vocabulary.applied",
                message: "Applied vocabulary mappings to recognized text.",
                metadata: [
                    "workflow": session.presentation.fallbackName,
                    "applicationCount": String(result.applications.count),
                    "replacementCount": String(replacementCount),
                    "issueCount": String(result.issues.count),
                ]
            )
        )
    }

    private func recordUnsupportedRecognitionHints(
        count: Int,
        recognizerID: String,
        session: RunSession
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: session.runID,
                subsystem: .providers,
                level: .info,
                event: "session.recognition-hints.unsupported",
                message: "The selected recognizer does not support the resolved recognition hints.",
                metadata: [
                    "count": String(count),
                    "outcome": "unsupported-recognizer",
                    "recognizerID": recognizerID,
                ]
            )
        )
    }

    private func recordCompiledPlan(
        _ plan: ResolvedWorkflowPlan,
        runID: UUID,
        workflow: WorkflowPresentation
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .session,
                level: .debug,
                event: "session.workflow-plan.compiled",
                message: "Compiled the workflow plan for this run.",
                metadata: [
                    "workflow": workflow.fallbackName,
                    "recognizerID": plan.recognizerID ?? "none",
                    "vocabularyCollectionCount": String(
                        plan.activeVocabularyCollectionCount
                    ),
                    "hotwordCount": String(plan.validHotwordCount),
                    "hotwordOmittedCount": String(plan.omittedHotwordCount),
                    "hotwordRejectedCount": String(plan.rejectedHotwordCount),
                    "hotwordOutcome":
                        plan.recognizerAcceptsHotwords ? "supported" : "unsupported-recognizer",
                ]
            )
        )
    }

    private func deliver(
        finalText: String,
        recognition: RecognitionResult,
        in session: RunSession
    ) async throws -> DeliveryExecutionSummary {
        state = .delivering(session.runID)
        let deliveryMetadata = [
            "actionCount": String(session.resolvedPlan.declaration.output.actions.count),
        ]
        await recordStage(
            .delivering,
            runID: session.runID,
            workflow: session.presentation,
            metadata: deliveryMetadata
        )
        let actionContext = ActionContext(
            runID: session.runID,
            workflow: session.workflow,
            contextSnapshot: session.contextSnapshot,
            recognitionResult: recognition,
            finalText: finalText,
            startedAt: session.startedAt,
            finishedAt: Date()
        )

        var summary = DeliveryExecutionSummary()
        for (actionIndex, reference) in
            session.resolvedPlan.declaration.output.actions.enumerated()
        {
            guard let action = actionRegistry.action(for: reference.id) else {
                throw SessionError.missingAction(reference.id)
            }
            let result: ActionResult
            do {
                result = try await executeRecordedAction(
                    action,
                    actionID: reference.id,
                    actionIndex: actionIndex,
                    text: finalText,
                    context: actionContext,
                    runID: session.runID,
                    workflow: session.presentation,
                    receiptIsActive: session.receiptIsActive
                )
            } catch is CancellationError {
                throw OutputActionCancellation(
                    successfulActionCount: summary.successfulActionCount
                )
            } catch let failure as CommittedOutputFailure {
                throw OutputActionExecutionFailure(
                    message: failure.message,
                    successfulActionCount: summary.successfulActionCount + 1
                )
            } catch {
                throw OutputActionExecutionFailure(
                    message: error.localizedDescription,
                    successfulActionCount: summary.successfulActionCount
                )
            }
            switch result {
            case .injected, .copiedToClipboard, .storedRecord, .externalOutput:
                summary.successfulActionCount += 1
            case .skipped:
                summary.skippedActionCount += 1
            case .failed(let message):
                throw OutputActionExecutionFailure(
                    message: message,
                    successfulActionCount: summary.successfulActionCount
                )
            }
        }
        return summary
    }

    @discardableResult
    private func complete(
        session: RunSession,
        finalText: String,
        correctionSource: RecognitionCorrectionSource? = nil
    ) async -> WorkflowRunSummary {
        let summary = WorkflowRunSummary(
            runID: session.runID,
            workflowID: session.workflow.id,
            workflow: session.presentation,
            trigger: session.trigger,
            finalText: finalText,
            correctionSource: correctionSource
        )
        await eventBus.publish(
            .runCompleted(summary)
        )
        await recordStage(
            .completed,
            runID: session.runID,
            workflow: session.presentation,
            metadata: ["durationMillis": String(Int(Date().timeIntervalSince(session.startedAt) * 1000))]
        )
        state = .idle
        return summary
    }
}

private struct TextTransformationResult: Sendable, Equatable {
    let finalText: String
    let languageModelInputTexts: [String]
    let languageModelTraces: [LanguageModelTrace]
}

private enum RunReceiptRegistration: Sendable, Equatable {
    case active
    case inactive
    case duplicate
}

private struct DeliveryExecutionSummary: Sendable, Equatable {
    var successfulActionCount = 0
    var skippedActionCount = 0

    var terminalReceipt: WorkflowRunTermination {
        if successfulActionCount == 0, skippedActionCount > 0 {
            return .skipped(reason: .allActionsSkipped)
        }
        if successfulActionCount > 0, skippedActionCount > 0 {
            return .partiallyCompleted(code: .processing)
        }
        return .completed
    }
}

private struct OutputActionExecutionFailure: Error, LocalizedError {
    let message: String
    let successfulActionCount: Int

    var errorDescription: String? { message }
}

private struct OutputActionCancellation: Error {
    let successfulActionCount: Int
}

private struct RunReceiptActionPreparationFailure: Error, LocalizedError {
    var errorDescription: String? {
        "The output action could not start because run receipt coordination failed."
    }
}

private extension SessionCoordinator.State {
    var runIdentifier: UUID? {
        switch self {
        case .idle:
            return nil
        case .running(let runID), .resolving(let runID), .delivering(let runID):
            return runID
        }
    }
}
