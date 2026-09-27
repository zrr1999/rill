import Foundation

/// The frozen speech-facing projection of a workflow. Prompts, actions and vocabulary bindings
/// stay with the workflow owner and cannot cross the audio service boundary.
public struct SpeechRequestConfiguration: Sendable, Equatable {
  public var presentation: WorkflowPresentation
  public var recognizerID: String?
  public var modelOverride: String?
  public var languageOverride: String?
  public var streamingProfile: String?
  public var livePreviewEnabled: Bool
  public var previewPlacement: LivePreviewPlacement
  public var isWakeCandidate: Bool

  public init(workflow: WorkflowDefinition) {
    presentation = workflow.presentation
    recognizerID = workflow.plan.setup.speechRoute?.recognizerID
    modelOverride =
      workflow.metadata[WorkflowMetadataKey.localSpeechModelOverride]
      ?? workflow.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride]
    languageOverride = workflow.metadata[WorkflowMetadataKey.languageOverride]
    streamingProfile = workflow.metadata[WorkflowMetadataKey.streamingProfile]
    livePreviewEnabled = workflow.livePreviewIsEnabled
    previewPlacement = workflow.resolvedLivePreviewPlacement
    isWakeCandidate = workflow.metadata["speech.task-priority"] == "wake-candidate"
  }
}
