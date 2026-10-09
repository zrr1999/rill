import Foundation
import RillCore

extension L10n {
  static func workflowActionResult(
    _ result: WorkflowActionResultCode,
    language: AppLanguage
  ) -> String {
    switch result {
    case .injected: return catalogString("workflowActionResult.injected", language: language)
    case .copiedToClipboard: return catalogString("workflowActionResult.copiedToClipboard", language: language)
    case .storedRecord: return catalogString("workflowActionResult.storedRecord", language: language)
    case .externalOutput: return catalogString("workflowActionResult.externalOutput", language: language)
    case .skipped: return catalogString("workflowActionResult.skipped", language: language)
    case .cancelled: return catalogString("workflowActionResult.cancelled", language: language)
    case .failed: return catalogString("workflowActionResult.failed", language: language)
    }
  }

  static func workflowRunTermination(
    _ termination: WorkflowRunTermination,
    language: AppLanguage
  ) -> String {
    switch termination {
    case .completed:
      return L10n.catalogString("Localization.HistoryRun.Completed", language: language)
    case .partiallyCompleted:
      return L10n.catalogString("Localization.HistoryRun.Partially.completed", language: language)
    case .failed:
      return L10n.catalogString("Localization.HistoryRun.Failed", language: language)
    case .cancelled:
      return L10n.catalogString("Localization.HistoryRun.Cancelled", language: language)
    case let .skipped(reason):
      let outcome = L10n.catalogString("Localization.HistoryRun.Skipped", language: language)
      return "\(outcome) — \(workflowRunSkipReason(reason, language: language))"
    }
  }

  static func workflowRunSkipReason(
    _ reason: WorkflowRunSkipCode,
    language: AppLanguage
  ) -> String {
    switch reason {
    case .workflowDisabled: return catalogString("workflowRunSkipReason.workflowDisabled", language: language)
    case .busy: return catalogString("workflowRunSkipReason.busy", language: language)
    case .unsupported: return catalogString("workflowRunSkipReason.unsupported", language: language)
    case .privacyBlocked: return catalogString("workflowRunSkipReason.privacyBlocked", language: language)
    case .eventKindMismatch: return catalogString("workflowRunSkipReason.eventKindMismatch", language: language)
    case .sourceCollectionMismatch: return catalogString("workflowRunSkipReason.sourceCollectionMismatch", language: language)
    case .excludedByCaptureTag: return catalogString("workflowRunSkipReason.excludedByCaptureTag", language: language)
    case .conditionFailed: return catalogString("workflowRunSkipReason.conditionFailed", language: language)
    case .recordMissing: return catalogString("workflowRunSkipReason.recordMissing", language: language)
    case .recordChanged: return catalogString("workflowRunSkipReason.recordChanged", language: language)
    case .loopPrevented: return catalogString("workflowRunSkipReason.loopPrevented", language: language)
    case .allActionsSkipped: return catalogString("workflowRunSkipReason.allActionsSkipped", language: language)
    case .unclassified: return catalogString("workflowRunSkipReason.unclassified", language: language)
    }
  }

  static func historyRunAccessibilityLabel(
    status: String,
    title: String,
    termination: WorkflowRunTermination?,
    language: AppLanguage
  ) -> String {
    let summary = "\(status): \(title)"
    guard case let .skipped(reason)? = termination else {
      return summary
    }
    return "\(summary), \(workflowRunSkipReason(reason, language: language))"
  }

  static func historyRunTrigger(
    _ trigger: WorkflowRunTriggerKind,
    language: AppLanguage
  ) -> String {
    switch trigger {
    case .manual: return catalogString("historyRunTrigger.manual", language: language)
    case .menuBar: return catalogString("historyRunTrigger.menuBar", language: language)
    case .hotkey: return catalogString("historyRunTrigger.hotkey", language: language)
    case .wakeWord: return catalogString("historyRunTrigger.wakeWord", language: language)
    case .recordCollectionEvent: return catalogString("historyRunTrigger.recordCollectionEvent", language: language)
    case .recordDelivery: return catalogString("historyRunTrigger.recordDelivery", language: language)
    case .recordUse: return catalogString("historyRunTrigger.recordUse", language: language)
    case .recordReplay: return catalogString("historyRunTrigger.recordReplay", language: language)
    case .failedAudioRecovery: return catalogString("historyRunTrigger.failedAudioRecovery", language: language)
    }
  }

  static func historyRunDurationBucket(
    _ bucket: WorkflowRunDurationBucket,
    language: AppLanguage
  ) -> String {
    switch bucket {
    case .under250ms: return catalogString("historyRunDurationBucket.under250ms", language: language)
    case .ms250To999: return catalogString("historyRunDurationBucket.ms250To999", language: language)
    case .s1To4: return catalogString("historyRunDurationBucket.s1To4", language: language)
    case .s5To14: return catalogString("historyRunDurationBucket.s5To14", language: language)
    case .s15To59: return catalogString("historyRunDurationBucket.s15To59", language: language)
    case .m1Plus: return catalogString("historyRunDurationBucket.m1Plus", language: language)
    case .unavailable: return catalogString("historyRunDurationBucket.unavailable", language: language)
    }
  }

  static func historyProcessingDuration(_ milliseconds: UInt64, language: AppLanguage) -> String {
    historyProcessingDurationResource(milliseconds).string(for: language)
  }

  static func historyProcessingDurationResource(_ milliseconds: UInt64) -> LocalizedStringResource {
    if milliseconds < 1_000 {
      return resource("history.duration.milliseconds", defaultValue: "\(String(milliseconds)) ms")
    }
    let fraction = String(format: "%03d", Int(milliseconds % 1_000))
    let seconds = "\(milliseconds / 1_000).\(fraction)"
    return resource("history.duration.seconds", defaultValue: "\(seconds) s")
  }

  /// Timeline status is a reason-free rollup of `WorkflowRunTermination`;
  /// the skipped case cannot carry the receipt's skip reason here, so the
  /// labels stay plain instead of routing through `workflowRunTermination`.
  static func historyRunStatus(
    _ status: HistoryTimelineStatus,
    language: AppLanguage
  ) -> String {
    switch status {
    case .completed: return catalogString("historyRunStatus.completed", language: language)
    case .partiallyCompleted: return catalogString("historyRunStatus.partiallyCompleted", language: language)
    case .failed: return catalogString("historyRunStatus.failed", language: language)
    case .cancelled: return catalogString("historyRunStatus.cancelled", language: language)
    case .skipped: return catalogString("historyRunStatus.skipped", language: language)
    }
  }

  static func historyTimelineText(
    _ key: HistoryTimelineTextKey,
    language: AppLanguage
  ) -> String {
    catalogString("historyTimeline.\(key.rawValue)", language: language)
  }

  static func historyTimelineAction(_ number: Int, language: AppLanguage) -> String {
    String(format: historyTimelineText(.actionFormat, language: language), number)
  }

  static func historyTimelineLLMRequestStep(_ step: Int, language: AppLanguage) -> String {
    String(format: historyTimelineText(.llmRequestStepFormat, language: language), step)
  }

  static func historyTimelineSentMessage(
    role: String,
    number: Int,
    language: AppLanguage
  ) -> String {
    String(
      format: historyTimelineText(.sentMessageFormat, language: language),
      role,
      number
    )
  }

  static func historyTimelineMessageRole(
    _ role: LanguageModelTraceMessage.Role,
    language: AppLanguage
  ) -> String {
    switch role {
    case .user: return catalogString("historyTimelineMessageRole.user", language: language)
    case .assistant: return catalogString("historyTimelineMessageRole.assistant", language: language)
    }
  }

  static func historyTimelineSentToLLMStep(_ step: Int, language: AppLanguage) -> String {
    String(format: historyTimelineText(.sentToLLMStepFormat, language: language), step)
  }

}

enum HistoryTimelineTextKey: String, CaseIterable, Sendable {
  case actionDetailsTruncated
  case actionFormat
  case copyFailureDetails
  case executionDetailsUnavailable
  case llmAnswer
  case llmRequest
  case llmRequestStepFormat
  case model
  case provider
  case recognizedInputLegacy
  case returnedText
  case sentMessageFormat
  case sentToLLM
  case sentToLLMStepFormat
  case systemPrompt
  case workflowPrompt
  case workflowRunFallback
}

enum HistoryRunDetailTextKey: String, CaseIterable, Sendable {
  case recording, transcription, polishing, languageModel, notRecorded
  case diagnostics, noDiagnostics, legacyDiagnostics, details, textResults
  case noDiagnosticIssues, showDiagnosticIssues, collapseDetails
}

extension L10n {
  static func historyRunDetail(_ key: HistoryRunDetailTextKey, language: AppLanguage) -> String {
    catalogString("historyRunDetail.\(key.rawValue)", language: language)
  }

  static func historyMeasuredDuration(_ milliseconds: UInt64?, language: AppLanguage) -> String {
    milliseconds.map { historyProcessingDuration($0, language: language) }
      ?? historyRunDetail(.notRecorded, language: language)
  }

  static func historyShowAllDiagnostics(_ count: Int, language: AppLanguage) -> String {
    L10n.resource("Localization.HistoryRun.Show.all", defaultValue: "Show all (\(String(describing: count)))").string(for: language)
  }

  static func historyStepResult(_ result: WorkflowStepResultCode, language: AppLanguage) -> String {

    switch result {
    case .completed: return L10n.resource("Localization.HistoryRun.Completed").string(for: language)
    case .thenBranch: return L10n.resource("Localization.HistoryRun.Then.branch").string(for: language)
    case .elseBranch: return L10n.resource("Localization.HistoryRun.Else.branch").string(for: language)
    case .skipped: return L10n.resource("Localization.HistoryRun.Skipped").string(for: language)
    case .failed: return L10n.resource("Localization.HistoryRun.Failed").string(for: language)
    case .cancelled: return L10n.resource("Localization.HistoryRun.Cancelled").string(for: language)
    }
  }
}
