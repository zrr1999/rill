import Foundation
import RillCore

extension L10n {
  enum WorkflowDocumentKey: String, CaseIterable {
    case labelWorkflows
    case labelEditExternally
    case labelRunClipboardText
    case labelRun
    case labelImportTOML
    case labelShowConfigurationFolder
    case labelReloadFiles
    case labelNewFrom
    case labelMoreActions
    case labelNewWorkflow
    case labelSearchWorkflows
    case labelEnabled
    case labelDuplicate
    case labelRestoreDefault
    case labelDelete
    case labelWorkflowActions
    case labelOpenFile
    case labelRemoveThisCustomization
    case labelRemove
    case labelInvalidFileNewRunsAreBlocked
    case labelPreset
    case labelSteps
    case labelOutputs
  }

  static func workflowDocument(_ key: WorkflowDocumentKey, language: AppLanguage) -> String {
    catalogString("workflowDocument.\(key.rawValue)", language: language)
  }
  static func modelServiceFailure(_ error: any Error) -> LocalizedStringResource? {
    guard let error = error as? LanguageModelConfigurationError else { return nil }
    switch error {
    case .decisionUnavailable: return resource("models.error.decision")
    case .speechSynthesisUnavailable: return resource("models.error.tts")
    case .unsupportedReasoning: return resource("models.error.reasoning")
    case .unavailable, .invalidConfiguration, .missingCredential: return resource("models.error.llm")
    }
  }

}
