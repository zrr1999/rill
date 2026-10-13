import Foundation
import RillCore

enum WorkflowStepPresentation {
  static func stepTitle(_ kind: WorkflowProcessStepKind, language: AppLanguage) -> String {
    titleResource(kind).string(for: language)
  }

  static func titleResource(_ kind: WorkflowProcessStepKind) -> LocalizedStringResource {
    return
      switch kind
    {
    case .recognizeSpeech: L10n.resource("WorkflowStepPresentation.Recognize.speech")
    case .resolveUncertainty: L10n.resource("WorkflowStepPresentation.Resolve.uncertainty")
    case .applyVocabulary: L10n.resource("WorkflowStepPresentation.Apply.vocabulary")
    case .snippetReplacement: L10n.resource("WorkflowStepPresentation.Replace.snippets")
    case .llmRewrite: L10n.resource("WorkflowStepPresentation.Rewrite")
    case .llmAnswer: L10n.resource("WorkflowStepPresentation.Answer")
    case .normalizeWhitespace:
      L10n.resource("WorkflowStepPresentation.Normalize.whitespace")
    case .conditional: L10n.resource("WorkflowStepPresentation.If")
    }
  }
}
