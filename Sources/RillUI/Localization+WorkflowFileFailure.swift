import Foundation
import RillCore

extension L10n {
  static func workflowFileFailure(_ error: Error) -> LocalizedStringResource {
    if error is WorkflowFileConflict { return resource("workflowFile.error.changed") }
    if let error = error as? WorkflowFileStoreError {
      switch error {
      case .configurationPathIsNotDirectory: return resource("workflowFile.error.configurationPathIsNotDirectory")
      case .fileOutsideConfigurationDirectory: return resource("workflowFile.error.fileOutsideConfigurationDirectory")
      case .unsupportedFile: return resource("workflowFile.error.unsupportedFile")
      case .fileTooLarge: return resource("workflowFile.error.fileTooLarge")
      case .unsupportedSchema: return resource("workflowFile.error.unsupportedSchema")
      case .invalidWorkflow: return resource("workflowFile.error.invalidWorkflow")
      }
    }
    if error is WorkflowDocumentError { return resource("workflowFile.error.invalidDocument") }
    return resource("workflowFile.error.system")
  }

  static func workflowFileIssue(_ issue: WorkflowFileIssue, language: AppLanguage) -> String {
    let summary: String
    switch issue.reason {
    case .file(let error): summary = workflowFileFailure(error).string(for: language)
    case .invalidDocument: summary = catalogString("workflowFile.error.invalidDocument", language: language)
    case .directoryUnreadable: summary = catalogString("workflowFile.error.directoryUnreadable", language: language)
    case .duplicateID: summary = catalogString("workflowFile.error.duplicateID", language: language)
    case .fileLimit(let count):
      summary = resource("workflowFile.error.fileLimit", defaultValue: "Only the first \(String(count)) TOML files were loaded.").string(for: language)
    }
    return "\(summary)\n\(issue.message)"
  }

  static func workflowFileFailureDetail(_ error: Error, language: AppLanguage) -> String {
    workflowFileFailureDetailResource(error).string(for: language)
  }

  static func workflowFileFailureDetailResource(_ error: Error) -> LocalizedStringResource {
    resource("workflowFile.error.details", defaultValue: "\(workflowFileFailure(error))\n\(error.localizedDescription)")
  }
}
