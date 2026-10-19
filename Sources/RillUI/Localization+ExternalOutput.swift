import RillCore

enum WorkflowExternalOutputField {
  case webhookURL
  case webhookHeadersJSON
  case shortcutName
  case markdownAppendPath
}

enum WorkflowExternalOutputValidationMessage {
  case webhookUnavailable
  case shortcutNameRequired
  case markdownPathRequired
  case markdownPathInvalid
}

extension L10n {
  static func externalOutputField(_ field: WorkflowExternalOutputField, language: AppLanguage) -> String {
    switch field {
    case .webhookURL: return catalogString("externalOutputField.webhookURL", language: language)
    case .webhookHeadersJSON: return catalogString("externalOutputField.webhookHeadersJSON", language: language)
    case .shortcutName: return catalogString("externalOutputField.shortcutName", language: language)
    case .markdownAppendPath: return catalogString("externalOutputField.markdownAppendPath", language: language)
    }
  }

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
