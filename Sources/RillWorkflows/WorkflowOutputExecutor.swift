import Foundation
import RillCore

struct WorkflowOutputExecutor: Sendable {
    let actionRegistry: OutputActionRegistry
    let runReceiptRecorder: WorkflowRunReceiptRecorder?
    let eventBus: EventBus
    let diagnostics: DiagnosticsRecorder?
    let lane: WorkflowRunLane
    private var runDiagnostics: WorkflowRunReporter { .init(diagnostics: diagnostics, eventBus: eventBus, lane: lane) }

    func deliver(
        finalText: String,
        recognition: RecognitionResult,
        in session: WorkflowRunSession
    ) async throws -> DeliveryExecutionSummary {
        var actionContext = ActionContext(
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
                throw SessionCoordinator.SessionError.missingAction(reference.id)
            }
            actionContext.actionConfiguration = session.resolvedPlan.outputConfigurations[actionIndex]
            let result: ActionResult
            do {
                try Task.checkCancellation()
                if let condition = reference.condition,
                   try !condition.evaluate(text: finalText, context: session.contextSnapshot) {
                    if session.receiptIsActive, let runReceiptRecorder {
                        try await runReceiptRecorder.beginAction(runID: session.runID, actionIndex: actionIndex)
                        try await runReceiptRecorder.finishAction(runID: session.runID, actionIndex: actionIndex, result: WorkflowActionResultCode.skipped)
                    }
                    summary.skippedActionCount += 1
                    continue
                }
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
        await runDiagnostics.recordStage(
            actionID == RecordActionID.store ? .saving : .delivering,
            runID: runID, workflow: workflow,
            metadata: ["actionCount": String(context.workflow.plan.output.actions.count)])
        let actionStartedAt = ContinuousClock.now
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
            await eventBus.publish(.actionExecuted(run: .init(runID: runID, lane: lane), actionID: actionID, result: result))
            await runDiagnostics.recordAction(
                runID: runID,
                workflow: workflow,
                actionID: actionID,
                result: result,
                durationMilliseconds: DiagnosticTiming.milliseconds(since: actionStartedAt)
            )
            throw failure
        } catch is CancellationError {
            await finishRecordedAction(
                runID: runID,
                actionIndex: actionIndex,
                result: .cancelled,
                receiptIsActive: receiptIsActive,
                failureDisposition: .unknown
            )
            throw CancellationError()
        } catch {
            await finishRecordedAction(
                runID: runID,
                actionIndex: actionIndex,
                result: .failed,
                receiptIsActive: receiptIsActive,
                failureDisposition: (error as? any OutputFailureDescribing)?.outputFailureDisposition ?? .unknown
            )
            await runDiagnostics.recordAction(
                runID: runID,
                workflow: workflow,
                actionID: actionID,
                result: .failed(""),
                durationMilliseconds: DiagnosticTiming.milliseconds(since: actionStartedAt)
            )
            throw error
        }

        await finishRecordedAction(
            runID: runID,
            actionIndex: actionIndex,
            result: WorkflowActionResultCode(result),
            receiptIsActive: receiptIsActive
        )
        await eventBus.publish(.actionExecuted(run: .init(runID: runID, lane: lane), actionID: actionID, result: result))
        await runDiagnostics.recordAction(
            runID: runID,
            workflow: workflow,
            actionID: actionID,
            result: result,
            durationMilliseconds: DiagnosticTiming.milliseconds(since: actionStartedAt)
        )
        return result
    }

    func finishRecordedAction(
        runID: UUID,
        actionIndex: Int,
        result: WorkflowActionResultCode,
        receiptIsActive: Bool,
        failureDisposition: OutputFailureDisposition? = nil
    ) async {
        guard receiptIsActive, let runReceiptRecorder else { return }
        do {
            try await runReceiptRecorder.finishAction(
                runID: runID,
                actionIndex: actionIndex,
                result: result,
                failureDisposition: failureDisposition
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

}

struct DeliveryExecutionSummary: Sendable, Equatable {
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

struct OutputActionExecutionFailure: Error, LocalizedError {
    let message: String
    let successfulActionCount: Int

    var errorDescription: String? { message }
}

struct OutputActionCancellation: Error {
    let successfulActionCount: Int
}

struct RunReceiptActionPreparationFailure: Error, LocalizedError {
    var errorDescription: String? {
        "The output action could not start because run receipt coordination failed."
    }
}
