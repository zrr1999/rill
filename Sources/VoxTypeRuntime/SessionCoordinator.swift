import Foundation
import VoxTypeCore

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
        case missingAction(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "A workflow run is already active."
            case .missingRecognizer(let id):
                return "No speech recognizer is registered for \(id)."
            case .missingAction(let id):
                return "No output action is registered for \(id)."
            }
        }
    }

    private var state: State = .idle
    private let contextProvider: any ContextProvider
    private let recognizerRegistry: SpeechRecognizerRegistry
    private let transformerRegistry: TextTransformerRegistry
    private let actionRegistry: OutputActionRegistry
    private let candidateResolver: CandidateResolver
    private let deliveryStack: DeliveryStack
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let defaultStackDeliveryActionID: String

    private struct RunSession: Sendable {
        let runID: UUID
        let workflow: WorkflowDefinition
        let contextSnapshot: ContextSnapshot
        let startedAt: Date

        var presentation: WorkflowPresentation {
            workflow.presentation
        }
    }

    public init(
        contextProvider: any ContextProvider,
        recognizerRegistry: SpeechRecognizerRegistry,
        transformerRegistry: TextTransformerRegistry,
        actionRegistry: OutputActionRegistry,
        candidateResolver: CandidateResolver,
        deliveryStack: DeliveryStack,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        defaultStackDeliveryActionID: String = "clipboard.copy"
    ) {
        self.contextProvider = contextProvider
        self.recognizerRegistry = recognizerRegistry
        self.transformerRegistry = transformerRegistry
        self.actionRegistry = actionRegistry
        self.candidateResolver = candidateResolver
        self.deliveryStack = deliveryStack
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.defaultStackDeliveryActionID = defaultStackDeliveryActionID
    }

    public func currentState() -> State {
        state
    }

    public func run(
        workflow: WorkflowDefinition,
        triggerEvent: WorkflowTriggerEvent? = nil,
        capturedAudio: CapturedAudio? = nil
    ) async {
        guard case .idle = state else {
            await publishFailure(runID: nil, workflow: nil, message: SessionError.alreadyRunning.localizedDescription)
            return
        }

        var runID: UUID?
        do {
            let session = await startRunSession(for: workflow)
            runID = session.runID
            let recognition = try await recognize(
                in: session,
                triggerEvent: triggerEvent,
                capturedAudio: capturedAudio
            )
            let resolvedRecognition = await resolveIfNeeded(recognition, in: session)
            let finalText = try await transformText(from: resolvedRecognition, in: session)
            try await deliver(finalText: finalText, recognition: resolvedRecognition, in: session)
            await complete(session: session, finalText: finalText)
        } catch {
            let failedWorkflow = workflow.presentation
            state = .idle
            if let runID {
                await recordStage(.failed, runID: runID, workflow: failedWorkflow)
            }
            await publishFailure(runID: runID, workflow: failedWorkflow, message: error.localizedDescription)
        }
    }

    public func deliverTopOfStack(actionID: String? = nil) async {
        await deliverNextClipboardItem(for: ClipboardRouteContext(), actionID: actionID)
    }

    public func deliverNextClipboardItem(
        for routeContext: ClipboardRouteContext,
        actionID: String? = nil
    ) async {
        let stackWorkflow = WorkflowPresentation(fallbackName: "Stack Delivery", titleKey: .stackDelivery)
        guard case .idle = state else {
            await publishFailure(
                runID: nil,
                workflow: stackWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }

        guard let lease = await deliveryStack.beginDeliveryLease(for: routeContext) else { return }
        let item = lease.item
        let selectedActionID = actionID ?? defaultStackDeliveryActionID
        let runID = UUID()
        state = .delivering(runID)
        await recordStage(.delivering, runID: runID, workflow: stackWorkflow)

        guard let action = actionRegistry.action(for: selectedActionID) else {
            await deliveryStack.failDelivery(
                leaseID: lease.leaseID,
                error: SessionError.missingAction(selectedActionID).localizedDescription
            )
            state = .idle
            await recordStage(.failed, runID: runID, workflow: stackWorkflow)
            await publishFailure(
                runID: runID,
                workflow: stackWorkflow,
                message: SessionError.missingAction(selectedActionID).localizedDescription
            )
            return
        }

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

        let context = await contextProvider.captureContext()
        let actionContext = ActionContext(
            runID: runID,
            workflow: workflow,
            contextSnapshot: context,
            recognitionResult: RecognitionResult(rawText: item.text, bestText: item.text),
            finalText: item.text,
            sourceClipboardItemID: nil,
            startedAt: item.createdAt,
            finishedAt: Date()
        )

        do {
            let result = try await action.execute(text: item.text, context: actionContext)
            await eventBus.publish(.actionExecuted(actionID: selectedActionID, result: result))
            await deliveryStack.completeDelivery(leaseID: lease.leaseID)
            state = .idle
            await eventBus.publish(
                .runCompleted(
                    WorkflowRunSummary(
                        runID: runID,
                        workflowID: workflow.id,
                        workflow: workflow.presentation,
                        finalText: item.text
                    )
                )
            )
            await recordStage(.completed, runID: runID, workflow: workflow.presentation)
        } catch {
            await deliveryStack.failDelivery(leaseID: lease.leaseID, error: error.localizedDescription)
            state = .idle
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
        }
    }

    public func deliverClipboardItem(itemID: UUID, actionID: String? = nil) async {
        let clipboardWorkflow = WorkflowPresentation(fallbackName: "Clipboard Item")
        guard case .idle = state else {
            await publishFailure(
                runID: nil,
                workflow: clipboardWorkflow,
                message: SessionError.alreadyRunning.localizedDescription
            )
            return
        }

        guard let item = await deliveryStack.item(id: itemID) else {
            await publishFailure(
                runID: nil,
                workflow: clipboardWorkflow,
                message: "The selected clipboard item is no longer available."
            )
            return
        }

        let selectedActionID = actionID ?? defaultStackDeliveryActionID
        let runID = UUID()
        state = .delivering(runID)
        await recordStage(.delivering, runID: runID, workflow: clipboardWorkflow)

        guard let action = actionRegistry.action(for: selectedActionID) else {
            state = .idle
            await recordStage(.failed, runID: runID, workflow: clipboardWorkflow)
            await publishFailure(
                runID: runID,
                workflow: clipboardWorkflow,
                message: SessionError.missingAction(selectedActionID).localizedDescription
            )
            return
        }

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
        let context = await contextProvider.captureContext()
        let actionContext = ActionContext(
            runID: runID,
            workflow: workflow,
            contextSnapshot: context,
            recognitionResult: RecognitionResult(rawText: item.text, bestText: item.text),
            finalText: item.text,
            sourceClipboardItemID: nil,
            startedAt: item.createdAt,
            finishedAt: Date()
        )

        do {
            let result = try await action.execute(text: item.text, context: actionContext)
            await eventBus.publish(.actionExecuted(actionID: selectedActionID, result: result))
            await deliveryStack.markUsed(itemID: itemID)
            state = .idle
            await eventBus.publish(
                .runCompleted(
                    WorkflowRunSummary(
                        runID: runID,
                        workflowID: workflow.id,
                        workflow: workflow.presentation,
                        finalText: item.text
                    )
                )
            )
            await recordStage(.completed, runID: runID, workflow: workflow.presentation)
        } catch {
            state = .idle
            await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
        }
    }

    public func replayClipboardItem(
        itemID: UUID,
        workflow: WorkflowDefinition,
        replacingSourceItem: Bool = false
    ) async {
        guard case .idle = state else {
            await publishFailure(runID: nil, workflow: workflow.presentation, message: SessionError.alreadyRunning.localizedDescription)
            return
        }

        guard let item = await deliveryStack.item(id: itemID) else {
            await publishFailure(runID: nil, workflow: workflow.presentation, message: "The selected clipboard item is no longer available.")
            return
        }

        var runID: UUID?
        do {
            let session = await startRunSession(for: workflow)
            runID = session.runID
            let replayRecognition = RecognitionResult(
                rawText: item.text,
                bestText: item.text,
                candidateSets: []
            )
            await eventBus.publish(.recognitionCompleted(replayRecognition))
            let finalText = try await transformText(from: replayRecognition, in: session)
            try await deliver(
                finalText: finalText,
                recognition: replayRecognition,
                in: session,
                sourceClipboardItemID: replacingSourceItem ? item.id : nil
            )
            await complete(session: session, finalText: finalText)
        } catch {
            state = .idle
            if let runID {
                await recordStage(.failed, runID: runID, workflow: workflow.presentation)
            }
            await publishFailure(runID: runID, workflow: workflow.presentation, message: error.localizedDescription)
        }
    }

    private func publishFailure(runID: UUID?, workflow: WorkflowPresentation?, message: String) async {
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

    private func recordStage(_ stage: WorkflowRunStage, runID: UUID, workflow: WorkflowPresentation) async {
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
                ]
            )
        )
    }

    private func startRunSession(for workflow: WorkflowDefinition) async -> RunSession {
        let runID = UUID()
        let startedAt = Date()
        state = .running(runID)
        await eventBus.publish(
            .runStarted(
                RunSnapshot(
                    runID: runID,
                    workflowID: workflow.id,
                    workflow: workflow.presentation,
                    startedAt: startedAt
                )
            )
        )
        await recordStage(.preparing, runID: runID, workflow: workflow.presentation)

        let contextSnapshot = await contextProvider.captureContext()
        await eventBus.publish(.contextCaptured(contextSnapshot))
        return RunSession(
            runID: runID,
            workflow: workflow,
            contextSnapshot: contextSnapshot,
            startedAt: startedAt
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

        await recordStage(.recognizing, runID: session.runID, workflow: session.presentation)
        let recognition = try await recognizer.recognize(
            RecognitionRequest(
                runID: session.runID,
                workflow: session.workflow,
                contextSnapshot: session.contextSnapshot,
                triggerEvent: triggerEvent,
                capturedAudio: capturedAudio
            )
        )
        await eventBus.publish(.recognitionCompleted(recognition))
        return recognition
    }

    private func resolveIfNeeded(_ recognition: RecognitionResult, in session: RunSession) async -> RecognitionResult {
        guard
            session.workflow.pipeline.uncertaintyPolicy.mode != .off,
            recognition.requiresResolution
        else {
            return recognition
        }

        state = .resolving(session.runID)
        await recordStage(.resolving, runID: session.runID, workflow: session.presentation)
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
        var finalText = recognition.bestText
        if !session.workflow.pipeline.postProcessSteps.isEmpty {
            await recordStage(.transforming, runID: session.runID, workflow: session.presentation)
        }

        for step in session.workflow.pipeline.postProcessSteps {
            guard let transformer = transformerRegistry.transformer(for: step.kind) else { continue }
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
            await eventBus.publish(.transformationApplied(stepID: step.id, text: finalText))
        }

        return finalText
    }

    private func deliver(
        finalText: String,
        recognition: RecognitionResult,
        in session: RunSession,
        sourceClipboardItemID: UUID? = nil
    ) async throws {
        state = .delivering(session.runID)
        await recordStage(.delivering, runID: session.runID, workflow: session.presentation)
        let actionContext = ActionContext(
            runID: session.runID,
            workflow: session.workflow,
            contextSnapshot: session.contextSnapshot,
            recognitionResult: recognition,
            finalText: finalText,
            sourceClipboardItemID: sourceClipboardItemID,
            startedAt: session.startedAt,
            finishedAt: Date()
        )

        for reference in session.workflow.pipeline.outputActions {
            guard let action = actionRegistry.action(for: reference.id) else {
                throw SessionError.missingAction(reference.id)
            }
            let result = try await action.execute(text: finalText, context: actionContext)
            await eventBus.publish(.actionExecuted(actionID: reference.id, result: result))
        }
    }

    private func complete(session: RunSession, finalText: String) async {
        await eventBus.publish(
            .runCompleted(
                WorkflowRunSummary(
                    runID: session.runID,
                    workflowID: session.workflow.id,
                    workflow: session.presentation,
                    finalText: finalText
                )
            )
        )
        await recordStage(.completed, runID: session.runID, workflow: session.presentation)
        state = .idle
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
