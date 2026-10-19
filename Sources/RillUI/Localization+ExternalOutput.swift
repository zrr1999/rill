import RillCore

enum WorkflowExternalOutputValidationMessage {
  case webhookUnavailable
  case shortcutNameRequired
  case markdownPathRequired
  case markdownPathInvalid
}

extension L10n {
  static func externalOutputHint(
    _ destination: WorkflowEditorDraft.DestinationChoice,
    language: AppLanguage
  ) -> String {
    return switch destination {
    case .sendToWebhook:
      L10n.resource("Localization.ExternalOutput.Webhook.output.is.unavailable.until.its.endpoint.and.headers.use.secure.storage").string(for: language)
    case .runShortcut: L10n.resource("Localization.ExternalOutput.Runs.a.macOS.Shortcut.and.passes.the.final.text.as.input").string(for: language)
    case .appendToMarkdown:
      L10n.resource("Localization.ExternalOutput.Atomically.appends.to.an.Obsidian.compatible.note.in.an.existing.folder.Linked.paths.and").string(
        for: language)
    default: ""
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
