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

    private var state: State = .idle
    private let privacyContextProvider: @Sendable () async -> ContextSnapshot
    private let recognizerRegistry: SpeechRecognizerRegistry
    private let transformerRegistry: TextTransformerRegistry
    private let actionRegistry: OutputActionRegistry
    private let candidateResolver: CandidateResolver
    private let deliveryStack: DeliveryStack
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let runReceiptRecorder: WorkflowRunReceiptRecorder?
    private let vocabularyRuleProvider: @Sendable () async throws -> [VocabularyRule]
    private let recognitionOptionsProvider: @Sendable (
        WorkflowDefinition,
        ContextSnapshot
    ) async -> SpeechRecognitionRequestOptions
    private let recognitionTimeoutPolicy: RecognitionTimeoutPolicy
    private let recognitionTimeoutExecutor: RecognitionTimeoutExecutor
    private let defaultStackDeliveryActionID: String

    private struct RunSession: Sendable {
        let runID: UUID
        let workflow: WorkflowDefinition
        let trigger: WorkflowRunTriggerKind
        let contextSnapshot: ContextSnapshot
        let recognitionOptions: SpeechRecognitionRequestOptions
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
        deliveryStack: DeliveryStack,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        runReceiptRecorder: WorkflowRunReceiptRecorder? = nil,
        vocabularyRuleProvider: @escaping @Sendable () async throws -> [VocabularyRule] = { [] },
        recognitionOptionsProvider: @escaping @Sendable (
            WorkflowDefinition,
            ContextSnapshot
        ) async -> SpeechRecognitionRequestOptions = { _, _ in .empty },
        recognitionTimeoutPolicy: RecognitionTimeoutPolicy = .standard,
        recognitionAudioCleanupOwner: ManagedTemporaryAudioCleanupOwner =
            ManagedTemporaryAudioCleanupOwner(),
        defaultStackDeliveryActionID: String = "clipboard.copy"
    ) {
        self.privacyContextProvider = privacyContextProvider
        self.recognizerRegistry = recognizerRegistry
        self.transformerRegistry = transformerRegistry
        self.actionRegistry = actionRegistry
        self.candidateResolver = candidateResolver
        self.deliveryStack = deliveryStack
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.runReceiptRecorder = runReceiptRecorder
        self.vocabularyRuleProvider = vocabularyRuleProvider
        self.recognitionOptionsProvider = recognitionOptionsProvider
        self.recognitionTimeoutPolicy = recognitionTimeoutPolicy
        self.recognitionTimeoutExecutor = RecognitionTimeoutExecutor(
            cleanupOwner: recognitionAudioCleanupOwner
        )
        self.defaultStackDeliveryActionID = defaultStackDeliveryActionID
    }

    public func currentState() -> State {
        state
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
        receiptTrigger: WorkflowRunTriggerKind? = nil
    ) async -> WorkflowRunExecutionResult {
        let runID = providedRunID ?? UUID()
        let effectiveReceiptTrigger = receiptTrigger ?? runReceiptTrigger(for: triggerEvent)
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

        guard case .idle = state else {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .busy)
            )
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
            try validateRegisteredOutputActions(in: workflow)
            let session = await startRunSession(
                for: workflow,
                runID: runID,
                trigger: effectiveReceiptTrigger,
                contextSnapshot: contextSnapshot,
                recognitionOptions: recognitionOptions,
                receiptIsActive: receiptIsActive
            )
            failureStage = .recognizing
            let recognition = try await recognize(
                in: session,
                triggerEvent: triggerEvent,
                capturedAudio: capturedAudio
            )
            failureStage = .resolving
            let resolvedRecognition = await resolveIfNeeded(recognition, in: session)
            let correctionSource = RecognitionCorrectionSource(
                preMappingText: resolvedRecognition.bestText,
                context: vocabularyContext(in: session)
            )
            failureStage = .transforming
            let finalText = try await transformText(from: resolvedRecognition, in: session)
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
        case .missingRecognizer, .missingTransformer, .missingAction, .unsupportedWorkflow,
             .privacyAuthorizationRequired, .authorizationInvocationMismatch:
            return .configuration
        }
    }

    private func validateRegisteredOutputActions(
        in workflow: WorkflowDefinition
    ) throws {
        for reference in workflow.pipeline.outputActions where actionRegistry.action(for: reference.id) == nil {
            throw SessionError.missingAction(reference.id)
        }
    }

    func deliverTopOfStack(actionID: String? = nil) async {
        await deliverNextClipboardItem(for: ClipboardRouteContext(), actionID: actionID)
    }

    func deliverNextClipboardItem(
        for routeContext: ClipboardRouteContext,
        actionID: String? = nil
    ) async {
        let selectedActionID = actionID ?? defaultStackDeliveryActionID
        let workflow = WorkflowDefinition(
            name: "Stack Delivery",
            titleKey: .stackDelivery,
            pipeline: PipelineDeclaration(
                recognizerID: "stack.replay",
                outputActions: [OutputActionReference(id: selectedActionID)],
                uncertaintyPolicy: .init(mode: .off),
                deliveryPolicy: .init(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "square.stack.3d.up.fill", accentColorName: "indigo")
        )
        let stackWorkflow = workflow.presentation
        let runID = UUID()
        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: .stackDelivery
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: stackWorkflow,
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
                workflow: stackWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }

        state = .delivering(runID)
        defer { state = .idle }

        guard let lease = await deliveryStack.beginDeliveryLease(for: routeContext) else {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .itemMissing)
            )
            return
        }
        let item = lease.item
        state = .delivering(runID)
        await recordStage(.delivering, runID: runID, workflow: stackWorkflow)

        guard let action = actionRegistry.action(for: selectedActionID) else {
            await deliveryStack.failDelivery(
                leaseID: lease.leaseID,
                error: SessionError.missingAction(selectedActionID).localizedDescription
            )
            await recordStage(.failed, runID: runID, workflow: stackWorkflow)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .delivering, code: .configuration)
            )
            await publishFailure(
                runID: runID,
                workflow: stackWorkflow,
                message: SessionError.missingAction(selectedActionID).localizedDescription
            )
            state = .idle
            return
        }

        let context = await privacyContextProvider()
        let actionContext = ActionContext(
            runID: runID,
            workflow: workflow,
            contextSnapshot: context,
            recognitionResult: RecognitionResult(rawText: item.text, bestText: item.text),
            finalText: item.text,
            startedAt: item.createdAt,
            finishedAt: Date()
        )

        do {
            let result = try await executeRecordedAction(
                action,
                actionID: selectedActionID,
                actionIndex: 0,
                text: item.text,
                context: actionContext,
                runID: runID,
                workflow: workflow.presentation,
                receiptIsActive: receiptIsActive
            )
            let deliverySummary: DeliveryExecutionSummary
            switch result {
            case .injected, .copiedToClipboard, .pushedToStack, .externalOutput:
                deliverySummary = DeliveryExecutionSummary(successfulActionCount: 1)
            case .skipped:
                deliverySummary = DeliveryExecutionSummary(skippedActionCount: 1)
            case .failed(let message):
                throw OutputActionExecutionFailure(
                    message: message,
                    successfulActionCount: 0
                )
            }
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: deliverySummary.terminalReceipt
            )
            await deliveryStack.completeDelivery(leaseID: lease.leaseID)
            await eventBus.publish(
                .runCompleted(
                    WorkflowRunSummary(
                        runID: runID,
                        workflowID: workflow.id,
                        workflow: workflow.presentation,
                        trigger: .stackDelivery,
                        finalText: item.text
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
                await deliveryStack.failDelivery(leaseID: lease.leaseID, error: nil)
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
            await deliveryStack.failDelivery(leaseID: lease.leaseID, error: error.localizedDescription)
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
            state = .idle
        }
    }

    func deliverClipboardItem(
        subject: ClipboardItemDryRunSubject,
        actionID: String? = nil,
        contextSnapshot: ContextSnapshot
    ) async {
        let selectedActionID = actionID ?? defaultStackDeliveryActionID
        let workflow = WorkflowDefinition(
            name: "Clipboard Item",
            pipeline: PipelineDeclaration(
                recognizerID: "clipboard.item",
                outputActions: [OutputActionReference(id: selectedActionID)],
                uncertaintyPolicy: .init(mode: .off),
                deliveryPolicy: .init(strategy: .immediate)
            ),
            ui: WorkflowUIConfig(symbolName: "doc.on.clipboard", accentColorName: "indigo")
        )
        let clipboardWorkflow = workflow.presentation
        let runID = UUID()
        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: .clipboardUse
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: clipboardWorkflow,
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
                workflow: clipboardWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }

        state = .delivering(runID)
        defer { state = .idle }

        let itemLease: ClipboardItemUseLease
        do {
            itemLease = try await deliveryStack.beginClipboardItemUseLease(
                matching: subject
            )
        } catch let error as ClipboardItemUseLeaseError {
            let reason: WorkflowRunSkipCode = error == .sourceUnavailable
                ? .itemMissing
                : .itemChanged
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: reason)
            )
            await publishFailure(
                runID: runID,
                workflow: clipboardWorkflow,
                message: error.localizedDescription
            )
            return
        } catch {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .itemChanged)
            )
            await publishFailure(
                runID: runID,
                workflow: clipboardWorkflow,
                message: "The selected clipboard item could not be claimed safely."
            )
            return
        }
        let item = itemLease.item

        state = .delivering(runID)
        await recordStage(.delivering, runID: runID, workflow: clipboardWorkflow)

        guard let action = actionRegistry.action(for: selectedActionID) else {
            await deliveryStack.failDelivery(leaseID: itemLease.leaseID, error: nil)
            await recordStage(.failed, runID: runID, workflow: clipboardWorkflow)
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .failed(stage: .delivering, code: .configuration)
            )
            await publishFailure(
                runID: runID,
                workflow: clipboardWorkflow,
                message: SessionError.missingAction(selectedActionID).localizedDescription
            )
            state = .idle
            return
        }

        let actionContext = ActionContext(
            runID: runID,
            workflow: workflow,
            contextSnapshot: contextSnapshot,
            recognitionResult: RecognitionResult(rawText: item.text, bestText: item.text),
            finalText: item.text,
            startedAt: item.createdAt,
            finishedAt: Date()
        )

        do {
            let result = try await executeRecordedAction(
                action,
                actionID: selectedActionID,
                actionIndex: 0,
                text: item.text,
                context: actionContext,
                runID: runID,
                workflow: workflow.presentation,
                receiptIsActive: receiptIsActive
            )
            let deliverySummary: DeliveryExecutionSummary
            switch result {
            case .injected, .copiedToClipboard, .pushedToStack, .externalOutput:
                deliverySummary = DeliveryExecutionSummary(successfulActionCount: 1)
            case .skipped:
                deliverySummary = DeliveryExecutionSummary(skippedActionCount: 1)
            case .failed(let message):
                throw OutputActionExecutionFailure(
                    message: message,
                    successfulActionCount: 0
                )
            }
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: deliverySummary.terminalReceipt
            )
            await deliveryStack.completeDelivery(leaseID: itemLease.leaseID)
            await eventBus.publish(
                .runCompleted(
                    WorkflowRunSummary(
                        runID: runID,
                        workflowID: workflow.id,
                        workflow: workflow.presentation,
                        trigger: .clipboardUse,
                        finalText: item.text
                    )
                )
            )
            await recordStage(.completed, runID: runID, workflow: workflow.presentation)
            state = .idle
        } catch {
            await deliveryStack.failDelivery(leaseID: itemLease.leaseID, error: nil)
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
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
            state = .idle
        }
    }

    func replayClipboardItem(
        itemID: UUID,
        authorizedContext: AuthorizedWorkflowRunContext,
        replacingSourceItem: Bool = false
    ) async {
        let runID = UUID()
        do {
            try await authorizedContext.consume()
        } catch {
            await rejectAuthorizedInvocation(
                runID: runID,
                workflow: authorizedContext.workflow,
                trigger: .clipboardReplay,
                message: error.localizedDescription
            )
            return
        }
        await replayClipboardItem(
            itemID: itemID,
            runID: runID,
            workflow: authorizedContext.workflow,
            contextSnapshot: authorizedContext.contextSnapshot,
            recognitionOptions: authorizedContext.recognitionOptions,
            replacingSourceItem: replacingSourceItem,
            authorizedInvocation: authorizedContext.invocation
        )
    }

    internal func replayClipboardItem(
        itemID: UUID,
        runID providedRunID: UUID? = nil,
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionOptions: SpeechRecognitionRequestOptions,
        replacingSourceItem: Bool = false,
        authorizedInvocation: WorkflowRunInvocation? = nil
    ) async {
        let runID = providedRunID ?? UUID()
        let receiptRegistration = await beginRunReceipt(
            runID: runID,
            workflowID: workflow.id,
            trigger: .clipboardReplay
        )
        if receiptRegistration == .duplicate {
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
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
            await publishFailure(runID: runID, workflow: workflow.presentation, message: SessionError.alreadyRunning.localizedDescription)
            return
        }

        state = .running(runID)
        defer { state = .idle }

        if let issue = WorkflowExecutionPolicy.issue(for: workflow) {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .unsupported)
            )
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: SessionError.unsupportedWorkflow(issue).localizedDescription
            )
            return
        }

        let item: ClipboardHistoryItem?
        var exactSubjectMismatch = false
        if let authorizedInvocation,
           case .clipboardItem(let subject, let operation) = authorizedInvocation {
            let requestedOperation: ClipboardItemDryRunOperation = replacingSourceItem
                ? .replace
                : .replay
            guard subject.itemID == itemID, operation == requestedOperation else {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .skipped(reason: .privacyBlocked)
                )
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: SessionError.authorizationInvocationMismatch.localizedDescription
                )
                return
            }
            item = await deliveryStack.item(matching: subject)
            if item == nil {
                exactSubjectMismatch = await deliveryStack.item(id: itemID) != nil
            }
        } else {
            item = await deliveryStack.item(id: itemID)
        }

        guard let item else {
            if exactSubjectMismatch {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .skipped(reason: .itemChanged)
                )
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: "The selected clipboard item changed before it could run."
                )
                return
            }
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .itemMissing)
            )
            await publishFailure(runID: runID, workflow: workflow.presentation, message: "The selected clipboard item is no longer available.")
            return
        }

        if let authorizedInvocation,
           !authorizedInvocation.authorizesClipboardItem(
               item,
               requestedItemID: itemID,
               replacingSourceItem: replacingSourceItem
           ) {
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: .skipped(reason: .privacyBlocked)
            )
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: SessionError.authorizationInvocationMismatch.localizedDescription
            )
            return
        }

        var failureStage = WorkflowRunStage.transforming
        do {
            let session = await startRunSession(
                for: workflow,
                runID: runID,
                trigger: .clipboardReplay,
                contextSnapshot: contextSnapshot,
                recognitionOptions: recognitionOptions,
                receiptIsActive: receiptIsActive
            )
            let replayRecognition = RecognitionResult(
                rawText: item.text,
                bestText: item.text,
                candidateSets: []
            )
            await eventBus.publish(.recognitionCompleted(replayRecognition))
            let finalText = try await transformText(from: replayRecognition, in: session)
            if let authorizedInvocation,
               case .clipboardItem(let subject, _) = authorizedInvocation,
               !(await deliveryStack.matchesClipboardItemDryRunSubject(subject)) {
                await finishRunReceipt(
                    runID: runID,
                    isActive: receiptIsActive,
                    termination: .skipped(reason: .itemChanged)
                )
                await publishFailure(
                    runID: runID,
                    workflow: workflow.presentation,
                    message: "The selected clipboard item changed while the workflow was preparing its result."
                )
                state = .idle
                return
            }
            failureStage = .delivering
            let deliverySummary = try await deliver(
                finalText: finalText,
                recognition: replayRecognition,
                in: session,
                sourceClipboardItemSubject: replacingSourceItem
                    ? authorizedInvocation?.clipboardItemSubject ?? clipboardItemSubject(for: item)
                    : nil
            )
            await finishRunReceipt(
                runID: runID,
                isActive: receiptIsActive,
                termination: deliverySummary.terminalReceipt
            )
            await complete(session: session, finalText: finalText)
        } catch {
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
                return
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
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
            state = .idle
        }
    }

}

private extension SessionCoordinator {
    func clipboardItemSubject(
        for item: ClipboardHistoryItem
    ) -> ClipboardItemDryRunSubject {
        ClipboardItemDryRunSubject(
            itemID: item.id,
            itemVersion: item.version,
            groupID: item.groupID,
            contentKind: item.contentKind,
            captureTags: item.captureTags,
            hasTransferableContent: item.supportsDirectPaste
        )
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
            result = try await action.execute(text: text, context: context)
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
        case .pushedToStack:
            return "pushedToStack"
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
        receiptIsActive: Bool
    ) async -> RunSession {
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
        let recognitionOptions: SpeechRecognitionRequestOptions
        if let providedRecognitionOptions {
            recognitionOptions = providedRecognitionOptions
        } else {
            recognitionOptions = await recognitionOptionsProvider(workflow, contextSnapshot)
        }
        return RunSession(
            runID: runID,
            workflow: workflow,
            trigger: trigger,
            contextSnapshot: contextSnapshot,
            recognitionOptions: recognitionOptions,
            startedAt: startedAt,
            receiptIsActive: receiptIsActive
        )
    }

    private func recognize(
        in session: RunSession,
        triggerEvent: WorkflowTriggerEvent?,
        capturedAudio: CapturedAudio?
    ) async throws -> RecognitionResult {
        guard let recognizer = recognizerRegistry.recognizer(for: session.workflow.pipeline.recognizerID) else {
            throw SessionError.missingRecognizer(session.workflow.pipeline.recognizerID)
        }

        await recordStage(
            .recognizing,
            runID: session.runID,
            workflow: session.presentation,
            metadata: ["recognizerID": session.workflow.pipeline.recognizerID]
        )
        var options = session.recognitionOptions
        if !recognizer.capabilities.supports(.keyterm), !options.hints.keyterms.isEmpty {
            await recordUnsupportedRecognitionHints(
                count: options.hints.keyterms.count,
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
            session.workflow.pipeline.uncertaintyPolicy.mode != .off,
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
            policy: session.workflow.pipeline.uncertaintyPolicy
        )
        let outcome = await candidateResolver.resolve(resolutionCase)
        await eventBus.publish(
            .candidateResolutionFinished(caseID: resolutionCase.id, resolvedText: outcome.result.bestText)
        )
        return outcome.result
    }

    private func transformText(
        from recognition: RecognitionResult,
        in session: RunSession
    ) async throws -> String {
        let vocabularyResult = await applyVocabularyRules(
            to: recognition.bestText,
            in: session
        )
        var finalText = vocabularyResult.text
        if vocabularyResult.changed ||
            !vocabularyResult.issues.isEmpty ||
            !session.workflow.pipeline.postProcessSteps.isEmpty {
            await recordStage(
                .transforming,
                runID: session.runID,
                workflow: session.presentation,
                metadata: [
                    "stepCount": String(session.workflow.pipeline.postProcessSteps.count),
                    "vocabularyApplicationCount": String(vocabularyResult.applications.count),
                    "vocabularyIssueCount": String(vocabularyResult.issues.count),
                ]
            )
        }

        for step in session.workflow.pipeline.postProcessSteps {
            guard let transformer = transformerRegistry.transformer(for: step.kind) else {
                throw SessionError.missingTransformer(step.kind)
            }
            finalText = try await transformer.transform(
                text: finalText,
                step: step,
                context: TransformContext(
                    runID: session.runID,
                    workflow: session.workflow,
                    contextSnapshot: session.contextSnapshot,
                    recognitionResult: recognition
                )
            )
            try Task.checkCancellation()
            await eventBus.publish(.transformationApplied(stepID: step.id, text: finalText))
            await recordTransformStep(
                runID: session.runID,
                workflow: session.presentation,
                step: step,
                transformerID: transformer.id
            )
        }

        return finalText
    }

    private func applyVocabularyRules(
        to text: String,
        in session: RunSession
    ) async -> VocabularyApplicationResult {
        let rules: [VocabularyRule]
        do {
            rules = try await vocabularyRuleProvider()
        } catch {
            await recordVocabularyProviderFailure(error, in: session)
            return VocabularyApplicationResult(text: text)
        }

        let result = VocabularyRuleApplicator.apply(
            text: text,
            rules: rules,
            context: vocabularyContext(in: session)
        )
        if result.changed || !result.issues.isEmpty {
            await recordVocabularyApplication(result, in: session)
        }
        return result
    }

    private func vocabularyContext(in session: RunSession) -> VocabularyRuleContext {
        VocabularyRuleContext(
            contextSnapshot: session.contextSnapshot,
            clipboardGroupID: session.workflow.targetClipboardGroupID,
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

    private func recordVocabularyProviderFailure(
        _: any Error,
        in session: RunSession
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: session.runID,
                subsystem: .session,
                level: .warning,
                event: "session.vocabulary.load-failed",
                message: "Vocabulary mappings could not be loaded.",
                metadata: ["reason": "rule-source-unavailable"]
            )
        )
    }

    private func deliver(
        finalText: String,
        recognition: RecognitionResult,
        in session: RunSession,
        sourceClipboardItemSubject: ClipboardItemDryRunSubject? = nil
    ) async throws -> DeliveryExecutionSummary {
        state = .delivering(session.runID)
        var deliveryMetadata = ["actionCount": String(session.workflow.pipeline.outputActions.count)]
        if let sourceClipboardItemSubject {
            deliveryMetadata["sourceClipboardItemID"] = sourceClipboardItemSubject.itemID.uuidString
        }
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
            sourceClipboardItemSubject: sourceClipboardItemSubject,
            startedAt: session.startedAt,
            finishedAt: Date()
        )

        var summary = DeliveryExecutionSummary()
        for (actionIndex, reference) in session.workflow.pipeline.outputActions.enumerated() {
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
            } catch {
                throw OutputActionExecutionFailure(
                    message: error.localizedDescription,
                    successfulActionCount: summary.successfulActionCount
                )
            }
            switch result {
            case .injected, .copiedToClipboard, .pushedToStack, .externalOutput:
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
