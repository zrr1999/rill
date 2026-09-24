import RillSpeechContracts
import RillCore
import RillSpeech

extension WakeWordTriggerSource {
  public func start(configuration: WakeWordConfiguration, workflow: WorkflowDefinition) async throws
  {
    try await start(
      configuration: configuration,
      workflow: WakeWordSpeechRequest(
        id: workflow.id, configuration: SpeechRequestConfiguration(workflow: workflow)))
  }
}

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
