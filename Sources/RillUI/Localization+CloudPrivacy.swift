import RillCore

extension L10n {
  public static func cloudPrivacyTitle(language: AppLanguage) -> String {
    return L10n.catalogString("Localization.CloudPrivacy.Allow.cloud.processing", language: language)
  }

  public static func cloudPrivacyAllowAndRemember(language: AppLanguage) -> String {
    return L10n.catalogString("Localization.CloudPrivacy.Allow.and.Remember", language: language)
  }

  public static func cloudPrivacyAllowOnce(language: AppLanguage) -> String {
    return L10n.catalogString("Localization.CloudPrivacy.Allow.Once", language: language)
  }

  public static func cloudPrivacyCancel(language: AppLanguage) -> String {
    return L10n.catalogString("Localization.CloudPrivacy.Cancel", language: language)
  }

  public static func cloudPrivacyAuthorization(language: AppLanguage) -> String {
    return L10n.catalogString("Localization.CloudPrivacy.Choose.Allow.and.Remember.to.skip.this.prompt.for.this.workflow.and", language: language)
  }

  public static func cloudPrivacyProcessing(
    workflowName: String, sendsSpeech: Bool, sendsText: Bool, language: AppLanguage
  ) -> String {
    switch (sendsSpeech, sendsText) {
    case (true, false):
      L10n.resource(
        "Localization.CloudPrivacy.The.workflow.will.stream.microphone.audio.and.any.matching.cloud.recognition.terms.to.its",
        defaultValue:
          "The workflow “\(String(describing: workflowName))” will stream microphone audio and any matching cloud-recognition terms to its cloud speech service while recording. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
      ).string(for: language)
    case (false, true):
      L10n.resource(
        "Localization.CloudPrivacy.The.workflow.will.send.its.final.transcript.to.the.configured.cloud.text.service.for",
        defaultValue:
          "The workflow “\(String(describing: workflowName))” will send its final transcript to the configured cloud text service for rewriting. Nothing from this run has left this Mac yet."
      ).string(for: language)
    case (true, true):
      L10n.resource(
        "Localization.CloudPrivacy.The.workflow.will.stream.microphone.audio.and.matching.cloud.recognition.terms.while.recording.then",
        defaultValue:
          "The workflow “\(String(describing: workflowName))” will stream microphone audio and matching cloud-recognition terms while recording, then send its final transcript to the configured cloud text service for rewriting. Rill continuously checks the current focus and privacy settings and stops the run if they become restricted. Nothing from this run has left this Mac yet."
      ).string(for: language)
    case (false, false):
      L10n.resource(
        "Localization.CloudPrivacy.The.workflow.requested.cloud.processing.but.its.cloud.destination.could.not.be.classified.Cancel",
        defaultValue:
          "The workflow “\(String(describing: workflowName))” requested cloud processing, but its cloud destination could not be classified. Cancel unless this is expected. Nothing from this run has left this Mac yet."
      ).string(for: language)
    }
  }
}
