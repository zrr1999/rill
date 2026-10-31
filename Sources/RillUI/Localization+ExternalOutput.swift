import RillCore

enum WorkflowExternalOutputValidationMessage {
  case webhookUnavailable
  case shortcutNameRequired
  case markdownPathRequired
  case markdownPathInvalid
}

extension L10n {
  static func externalOutputValidationMessage(
    _ message: WorkflowExternalOutputValidationMessage,
    language: AppLanguage
  ) -> String {
    switch message {
    case .webhookUnavailable: return catalogString("externalOutputValidationMessage.webhookUnavailable", language: language)
    case .shortcutNameRequired: return catalogString("externalOutputValidationMessage.shortcutNameRequired", language: language)
    case .markdownPathRequired: return catalogString("externalOutputValidationMessage.markdownPathRequired", language: language)
    case .markdownPathInvalid: return catalogString("externalOutputValidationMessage.markdownPathInvalid", language: language)
    }
  }
}
