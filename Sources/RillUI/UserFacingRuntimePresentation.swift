import Foundation
import RillCore

enum RunFailurePresentation {
  static func localizedText(for untrustedMessage: String?) -> LocalizedStringResource {
    let safeMessage =
      HistoryFailureSanitizer.sanitize(untrustedMessage)
      ?? HistoryFailureSanitizer.genericMessage
    switch safeMessage {
    case "Microphone access is required. Grant access in System Settings and retry.":
      return L10n.resource("failure.microphone", defaultValue: "\(safeMessage)")
    case "Accessibility access is required for direct text insertion. Grant access and retry.":
      return L10n.resource("failure.accessibility", defaultValue: "\(safeMessage)")
    case "The run was blocked by the current privacy policy. Review Privacy settings and retry.":
      return L10n.resource("failure.privacy", defaultValue: "\(safeMessage)")
    case HistoryFailureSanitizer.noSpeechMessage:
      return L10n.resource("failure.noSpeech", defaultValue: "\(safeMessage)")
    case HistoryFailureSanitizer.globalInputUnavailableMessage:
      return L10n.resource("failure.globalInputUnavailable", defaultValue: "\(safeMessage)")
    case HistoryFailureSanitizer.recognitionTimeoutMessage:
      return L10n.resource("failure.recognitionTimeout", defaultValue: "\(safeMessage)")
    case HistoryFailureSanitizer.recognitionRecoveryPendingMessage:
      return L10n.resource("failure.recognitionRecoveryPending", defaultValue: "\(safeMessage)")
    default:
      return L10n.resource("failure.generic", defaultValue: "\(safeMessage)")
    }
  }

  static func historyText(for message: String?, language: AppLanguage) -> String {
    if HistoryFailureSanitizer.sanitize(message) == HistoryFailureSanitizer.genericMessage {
      return L10n.catalogString("UserFacingRuntimePresentation.Processing.did.not.complete.Expand.execution.details.to.see.why", language: language)
    }
    return text(for: message, language: language)
  }

  static func text(
    for untrustedMessage: String?,
    language: AppLanguage
  ) -> String {
    localizedText(for: untrustedMessage).string(for: language)
  }
}

enum DiagnosticsTimelineFilter: String, CaseIterable, Identifiable, Sendable {
  case activity
  case issues
  case all

  var id: String { rawValue }

  func title(language: AppLanguage) -> String {
    switch self {
    case .activity: L10n.resource("UserFacingRuntimePresentation.Activity").string(for: language)
    case .issues: L10n.resource("UserFacingRuntimePresentation.Issues").string(for: language)
    case .all: L10n.resource("UserFacingRuntimePresentation.All.Details").string(for: language)
    }
  }

  func includes(_ event: DiagnosticEvent) -> Bool {
    switch self {
    case .activity:
      event.level != .debug
    case .issues:
      event.level == .warning || event.level == .error
    case .all:
      true
    }
  }
}

enum DiagnosticEventPresentation {
  private static let genericMessage = "Diagnostic event recorded."

  static func title(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String {
    if let known = knownTitle(for: event, language: language) {
      return known
    }
    if event.message != genericMessage {
      return language == .english
        ? event.message
        : localizedFallbackTitle(for: event, language: language)
    }
    return localizedFallbackTitle(for: event, language: language)
  }

  static func detail(for event: DiagnosticEvent) -> String {
    let metadata = event.metadata
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " · ")
    return metadata.isEmpty ? event.event : "\(event.event) · \(metadata)"
  }

  private static func knownTitle(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String? {
    switch event.name {
    case .globalInputInstalled:
      return L10n.catalogString("UserFacingRuntimePresentation.Global.input.is.ready", language: language)
    case .globalInputUnavailable:
      return L10n.catalogString("UserFacingRuntimePresentation.Global.input.is.unavailable", language: language)
    case .historyMaintenanceCompleted:
      return L10n.catalogString("UserFacingRuntimePresentation.History.cleanup.completed", language: language)
    case .clipboardCapturePaused:
      return L10n.catalogString("UserFacingRuntimePresentation.Clipboard.capture.is.paused", language: language)
    case .clipboardCaptureResumed:
      return L10n.catalogString("UserFacingRuntimePresentation.Clipboard.capture.is.active", language: language)
    case .temporaryFilesCleanupCompleted:
      return L10n.catalogString("UserFacingRuntimePresentation.Temporary.recordings.cleaned.up", language: language)
    case .securityWebhookConfigurationProtected:
      return L10n.catalogString("UserFacingRuntimePresentation.Webhook.credentials.are.protected", language: language)
    case .providerLocalSpeechAvailable, .providerSherpaOnnxAvailable:
      return L10n.catalogString("UserFacingRuntimePresentation.On.device.speech.support.is.available", language: language)
    case .workflowManifestLoaded:
      return L10n.catalogString("UserFacingRuntimePresentation.Workflow.catalog.loaded", language: language)
    case .persistenceSqliteReady:
      return L10n.catalogString("UserFacingRuntimePresentation.Local.storage.is.ready", language: language)
    case .workflowAudioRecordingStarted:
      return L10n.catalogString("UserFacingRuntimePresentation.Recording.started", language: language)
    case .workflowAudioRecordingQueued:
      return L10n.catalogString("UserFacingRuntimePresentation.Recording.queued.for.on.device.transcription", language: language)
    case .workflowAudioRecordingTerminalSignal:
      return L10n.catalogString("UserFacingRuntimePresentation.Recording.finished", language: language)
    case .recordingStarted:
      return L10n.catalogString("UserFacingRuntimePresentation.Recording.started", language: language)
    case .recordingHotkeyPressed:
      return L10n.catalogString("UserFacingRuntimePresentation.Push.to.talk.pressed", language: language)
    case .recordingHotkeyReleased:
      return L10n.catalogString("UserFacingRuntimePresentation.Push.to.talk.released", language: language)
    case .recordingFinishing:
      return L10n.catalogString("UserFacingRuntimePresentation.Finishing.recording", language: language)
    case .recordingQueued:
      return L10n.catalogString("UserFacingRuntimePresentation.Recording.queued.for.transcription", language: language)
    case .audioProcessingEnqueued:
      return L10n.catalogString("UserFacingRuntimePresentation.Audio.queued.for.processing", language: language)
    case .audioProcessingStarted:
      return L10n.catalogString("UserFacingRuntimePresentation.Audio.processing.started", language: language)
    case .audioProcessingTemporaryFileRemoved:
      return L10n.catalogString("UserFacingRuntimePresentation.Temporary.recording.removed", language: language)
    case .sessionTransformStep:
      return L10n.catalogString("UserFacingRuntimePresentation.Text.cleanup.applied", language: language)
    case .sessionAction:
      return L10n.catalogString("UserFacingRuntimePresentation.Output.action.completed", language: language)
    case .clipboardInjectTextPrepare:
      return L10n.catalogString("UserFacingRuntimePresentation.Preparing.text.insertion", language: language)
    case .clipboardInjectPasteBegin:
      return L10n.catalogString("UserFacingRuntimePresentation.Text.insertion.started", language: language)
    case .clipboardInjectPasteEnd:
      return L10n.catalogString("UserFacingRuntimePresentation.Text.insertion.finished", language: language)
    case .clipboardInjectRestore:
      return L10n.catalogString("UserFacingRuntimePresentation.Clipboard.restored", language: language)
    case .sessionStage:
      return sessionStageTitle(
        event.metadata["stage"],
        language: language
      )
    default:
      return nil
    }
  }

  private static func sessionStageTitle(
    _ stage: String?,
    language: AppLanguage
  ) -> String? {
    switch stage {
    case "preparing":
      return L10n.catalogString("UserFacingRuntimePresentation.Preparing.workflow", language: language)
    case "recognizing":
      return L10n.catalogString("UserFacingRuntimePresentation.Recognizing.speech.on.device", language: language)
    case "transforming":
      return L10n.catalogString("UserFacingRuntimePresentation.Formatting.transcription", language: language)
    case "saving":
      return L10n.catalogString("UserFacingRuntimePresentation.Saving.text", language: language)
    case "delivering":
      return L10n.catalogString("UserFacingRuntimePresentation.Delivering.text", language: language)
    case "completed":
      return L10n.catalogString("UserFacingRuntimePresentation.Workflow.completed", language: language)
    default:
      return nil
    }
  }

  private static func localizedFallbackTitle(
    for event: DiagnosticEvent,
    language: AppLanguage
  ) -> String {
    let subsystem = L10n.subsystem(event.subsystem, language: language)
    return L10n.resource("UserFacingRuntimePresentation.event", defaultValue: "\(String(describing: subsystem)) event: \(String(describing: event.event))")
      .string(for: language)
  }

}
