import Foundation

/// A payload-free error boundary for local speech model preparation.
///
/// Provider errors must be mapped to one of these allowlisted stages before
/// they cross into UI state. The generic case is the only fallback for errors
/// that do not implement the trusted loader contract.
public struct LocalSpeechPreparationFailure: Error, Equatable, Sendable {
  public enum Stage: String, CaseIterable, Sendable {
    case architectureUnsupported = "architecture-unsupported"
    case trustMaterialUnavailable = "trust-material-unavailable"
    case trustRoot
    case resolution
    case integrity
    case tokenizer
    case runtime
    case generic
  }

  public let stage: Stage

  public init(stage: Stage) {
    self.stage = stage
  }
}

extension LocalSpeechPreparationFailure: LocalizedError {
  public var errorDescription: String? {
    L10n.localSpeechPreparationFailure(stage).english
  }
}
