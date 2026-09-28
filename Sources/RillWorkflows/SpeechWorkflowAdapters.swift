import RillSpeechContracts
import RillCore
import RillSpeech

extension LocalSpeechModelCatalog {
  public static func effectiveModelIdentifier(
    settings: LocalSpeechSettings,
    workflow: WorkflowDefinition?
  ) -> String {
    return effectiveModelIdentifier(
      settings: settings,
      modelOverride: workflow.flatMap {
        $0.metadata[WorkflowMetadataKey.localSpeechModelOverride]
          ?? $0.metadata[WorkflowMetadataKey.legacyWhisperKitModelOverride]
      })
  }

}
