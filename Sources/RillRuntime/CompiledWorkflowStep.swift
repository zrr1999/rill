import Foundation
import RillCore

/// Only the compiler creates executable steps; TOML editing keeps its separate document shape.
public struct CompiledWorkflowStep: Sendable, Equatable {
  public enum Operation: Sendable, Equatable {
    case recognizeSpeech
    case resolveUncertainty(UncertaintyPolicy)
    case applyVocabulary
    case transform(PostProcessStep)
    case conditional(
      WorkflowCondition, then: [CompiledWorkflowStep], otherwise: [CompiledWorkflowStep])
  }

  public let id: UUID
  public let index: Int
  public let kind: WorkflowProcessStepKind
  public let operation: Operation

  static func compile(_ documents: [WorkflowProcessStep], nextIndex: inout Int) throws -> [Self] {
    try documents.map { document in
      let index = nextIndex
      nextIndex += 1
      let operation: Operation
      switch document.kind {
      case .recognizeSpeech: operation = .recognizeSpeech
      case .resolveUncertainty:
        operation = .resolveUncertainty(document.uncertaintyPolicy ?? UncertaintyPolicy(mode: .off))
      case .applyVocabulary: operation = .applyVocabulary
      case .conditional:
        guard let condition = document.condition else {
          throw WorkflowPlanCompilationError.invalidPlan("An if step is missing its condition.")
        }
        operation = .conditional(
          condition,
          then: try compile(document.thenSteps ?? [], nextIndex: &nextIndex),
          otherwise: try compile(document.elseSteps ?? [], nextIndex: &nextIndex))
      case .snippetReplacement, .llmRewrite, .llmAnswer, .normalizeWhitespace:
        guard let step = document.postProcessStep else {
          throw WorkflowPlanCompilationError.invalidPlan("The text step is invalid.")
        }
        operation = .transform(step)
      }
      return Self(id: document.id, index: index, kind: document.kind, operation: operation)
    }
  }
}
