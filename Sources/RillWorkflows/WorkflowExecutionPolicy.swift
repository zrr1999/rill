import RillCore

public enum WorkflowExecutionSurface: Sendable, Equatable {
  case interactiveCapture
  case clipboardItemReplay
  case recordCollectionEvent
}

public enum WorkflowExecutionSurfaceDecision: Sendable, Equatable {
  case supported
  case wrongSurface
  case invalidConfiguration
}

public enum WorkflowExecutionPolicyIssue: String, Codable, Sendable, Equatable {
  case wrongExecutionSurface
  case invalidConfiguration
  case plannedCapabilityUnavailable
}

public enum WorkflowExecutionPolicy {
  public static func issue(
    for workflow: WorkflowDefinition
  ) -> WorkflowExecutionPolicyIssue? {
    guard workflow.availability == .active else {
      return .plannedCapabilityUnavailable
    }
    switch decision(for: workflow, on: .interactiveCapture) {
    case .supported:
      return nil
    case .wrongSurface:
      return .wrongExecutionSurface
    case .invalidConfiguration:
      return .invalidConfiguration
    }
  }

  public static func supports(_ workflow: WorkflowDefinition) -> Bool {
    issue(for: workflow) == nil
  }

  public static func decision(
    for workflow: WorkflowDefinition,
    on surface: WorkflowExecutionSurface
  ) -> WorkflowExecutionSurfaceDecision {
    guard workflow.availability == .active else { return .invalidConfiguration }
    if workflow.trigger == .wakeWord {
      guard let configuration = workflow.plan.setup.wakeWord,
        (try? configuration.validatedPhrases()) != nil
      else {
        return .invalidConfiguration
      }
    } else if workflow.plan.setup.wakeWord != nil {
      return .invalidConfiguration
    }
    if workflow.properties.automation != nil { return surface == .recordCollectionEvent ? .supported : .wrongSurface }
    return surface == .recordCollectionEvent ? .wrongSurface : .supported
  }
}
