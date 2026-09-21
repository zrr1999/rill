import Foundation
import RillCore

struct WorkflowRunSession: Sendable {
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

struct WorkflowTextExecutor: Sendable {
  let transformerRegistry: TextTransformerRegistry
  let runReceiptRecorder: WorkflowRunReceiptRecorder?
  let eventBus: EventBus
  let diagnostics: DiagnosticsRecorder?
  let lane: WorkflowRunLane
  let processingClock: @Sendable () -> UInt64
  private var runDiagnostics: WorkflowRunDiagnostics { .init(diagnostics: diagnostics) }

  func transformText(
    from recognition: RecognitionResult,
    in session: WorkflowRunSession,
    initialSteps: [WorkflowTextStep],
    correctionContext: RunContextPreparation.Frozen? = nil,
    allowsSpeechTextFallback: Bool = false
  ) async throws -> TextTransformationResult {
    var finalText = recognition.bestText
    var references = correctionContext?.receipt
    var languageModelInputTexts: [String] = []
    var languageModelTraces: [LanguageModelTrace] = []
    var processingSteps = initialSteps
    var didRecordTransformStage = false
    var pendingSteps = Array(session.resolvedPlan.steps.reversed())
    while let processStep = pendingSteps.popLast() {
      try Task.checkCancellation()
      if processStep.kind == .recognizeSpeech || processStep.kind == .resolveUncertainty {
        continue
      }
      let inputText = finalText
      var processingStartedAt: UInt64?
      var durationMilliseconds: UInt64?
      if session.receiptIsActive, let runReceiptRecorder {
        try await runReceiptRecorder.beginStep(
          runID: session.runID, stepIndex: processStep.index, kind: processStep.kind)
      }
      do {
        processingStartedAt = processStep.recordsDuration ? processingClock() : nil
        switch processStep.operation {
        case .conditional(let condition, let thenSteps, let elseSteps):
          let selected = try condition.evaluate(text: finalText, context: session.contextSnapshot)
          pendingSteps.append(contentsOf: (selected ? thenSteps : elseSteps).reversed())
          durationMilliseconds = processingStartedAt.flatMap(processingDurationMilliseconds)
          try await finishProcessReceipt(
            session, result: selected ? .thenBranch : .elseBranch,
            durationMilliseconds: durationMilliseconds
          )
          processingSteps.append(
            await recordTextStep(
              kind: .conditional, result: selected ? .thenBranch : .elseBranch,
              durationMilliseconds: durationMilliseconds, in: session
            ))
          continue
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
              await runDiagnostics.recordStage(
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
          durationMilliseconds = processingStartedAt.flatMap(processingDurationMilliseconds)
          try await finishProcessReceipt(session, result: .completed, durationMilliseconds: durationMilliseconds)
          processingSteps.append(
            await recordTextStep(
              kind: processStep.kind, text: finalText, previousText: inputText,
              durationMilliseconds: durationMilliseconds, in: session
            ))
          continue
        case .transform:
          break
        }
        guard case .transform(let step) = processStep.operation else { continue }
        if !didRecordTransformStage {
          await runDiagnostics.recordStage(
            .transforming,
            runID: session.runID,
            workflow: session.presentation,
            metadata: [
              "stepCount": String(
                session.resolvedPlan.declaration.process.steps.count
              )
            ]
          )
          didRecordTransformStage = true
        }
        guard let transformer = transformerRegistry.transformer(for: step.kind) else {
          throw SessionCoordinator.SessionError.missingTransformer(step.kind)
        }
        if step.kind == .llmRewrite || step.kind == .llmAnswer {
          languageModelInputTexts.append(finalText)
        }
        var tokenUsage: LanguageModelTokenUsage?
        do {
          var correctionRequest = step.kind == .llmRewrite ? correctionContext?.request : nil
          // References stay frozen; explicit candidate choices and local vocabulary still update the transcript.
          correctionRequest?.transcript = finalText
          let context = TransformContext(
            runID: session.runID,
            workflow: session.workflow,
            contextSnapshot: session.contextSnapshot,
            recognitionResult: recognition,
            correctionRequest: correctionRequest
          )
          processingStartedAt = processStep.recordsDuration ? processingClock() : nil
          if let tracedTransformer = transformer as? any TracedTextTransformer,
            step.kind == .llmRewrite || step.kind == .llmAnswer
          {
            let result = try await tracedTransformer.transformWithTrace(
              text: finalText,
              step: step,
              context: context
            )
            finalText = result.text
            if let request = correctionContext?.request {
              if request.referenceImage != nil { references?.image = .sent }
              if request.imageSummary != nil { references?.imageSummary = .sent }
              if request.memorySummary != nil { references?.memorySummary = .sent }
            }
            languageModelTraces.append(result.trace)
            tokenUsage = result.trace.tokenUsage
          } else {
            finalText = try await transformer.transform(
              text: finalText,
              step: step,
              context: context
            )
          }
          durationMilliseconds = processingStartedAt.flatMap(processingDurationMilliseconds)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as any SpeechTextFallbackEligibleError
          where allowsSpeechTextFallback
          && step.kind == .llmRewrite
          && error.allowsSpeechTextFallback
        {
          durationMilliseconds = processingStartedAt.flatMap(processingDurationMilliseconds)
          if let request = correctionContext?.request {
            if request.referenceImage != nil { references?.image = .deliveryUnconfirmed }
            if request.imageSummary != nil { references?.imageSummary = .deliveryUnconfirmed }
            if request.memorySummary != nil { references?.memorySummary = .deliveryUnconfirmed }
          }
          await recordSpeechTextTransformFallback(
            runID: session.runID,
            workflow: session.presentation,
            step: step,
            transformerID: transformer.id
          )
          try await finishProcessReceipt(
            session, result: .skipped, durationMilliseconds: durationMilliseconds)
          processingSteps.append(
            await recordTextStep(
              kind: processStep.kind, result: .skipped,
              text: finalText, previousText: inputText,
              durationMilliseconds: durationMilliseconds, in: session
            ))
          continue
        }
        try Task.checkCancellation()
        await eventBus.publish(
          .transformationApplied(
            run: .init(runID: session.runID, lane: lane), stepID: step.id, text: finalText))
        await runDiagnostics.recordTransformStep(
          runID: session.runID,
          workflow: session.presentation,
          step: step,
          transformerID: transformer.id
        )
        try await finishProcessReceipt(
          session, result: .completed, durationMilliseconds: durationMilliseconds)
        processingSteps.append(
          await recordTextStep(
            kind: processStep.kind, text: finalText, previousText: inputText,
            tokenUsage: tokenUsage, durationMilliseconds: durationMilliseconds, in: session
          ))
      } catch {
        durationMilliseconds =
          durationMilliseconds ?? processingStartedAt.flatMap(processingDurationMilliseconds)
        try? await finishProcessReceipt(
          session, result: error is CancellationError ? .cancelled : .failed,
          durationMilliseconds: durationMilliseconds
        )
        _ = await recordTextStep(
          kind: processStep.kind,
          result: error is CancellationError ? .cancelled : .failed,
          durationMilliseconds: durationMilliseconds,
          in: session
        )
        throw error
      }
    }

    return TextTransformationResult(
      finalText: finalText,
      languageModelInputTexts: languageModelInputTexts,
      languageModelTraces: languageModelTraces,
      processingSteps: processingSteps,
      references: references
    )
  }

  func recordTextStep(
    kind: WorkflowProcessStepKind,
    result: WorkflowStepResultCode = .completed,
    text: String? = nil,
    previousText: String? = nil,
    tokenUsage: LanguageModelTokenUsage? = nil,
    durationMilliseconds: UInt64? = nil,
    in session: WorkflowRunSession
  ) async -> WorkflowTextStep {
    let step = WorkflowTextStep(
      kind: kind, result: result, outputText: text,
      didChange: previousText.map { $0 != text }, tokenUsage: tokenUsage,
      durationMilliseconds: durationMilliseconds
    )
    await runReceiptRecorder?.recordTextStep(runID: session.runID, step: step)
    await eventBus.publish(.runTextStepRecorded(runID: session.runID, step: step))
    return step
  }

  func processingDurationMilliseconds(since startedAt: UInt64) -> UInt64? {
    let finishedAt = processingClock()
    guard finishedAt >= startedAt else { return nil }
    return (finishedAt - startedAt) / 1_000_000
  }

  func finishProcessReceipt(
    _ session: WorkflowRunSession, result: WorkflowStepResultCode,
    durationMilliseconds: UInt64? = nil
  ) async throws {
    guard session.receiptIsActive, let runReceiptRecorder else { return }
    try await runReceiptRecorder.finishStep(
      runID: session.runID, result: result, durationMilliseconds: durationMilliseconds)
  }

  func recordSpeechTextTransformFallback(
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

  func recordVocabularyApplication(
    _ result: VocabularyApplicationResult,
    in session: WorkflowRunSession
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
}

struct TextTransformationResult: Sendable, Equatable {
  let finalText: String
  let languageModelInputTexts: [String]
  let languageModelTraces: [LanguageModelTrace]
  let processingSteps: [WorkflowTextStep]
  var references: CorrectionReferenceReceipt? = nil
}
