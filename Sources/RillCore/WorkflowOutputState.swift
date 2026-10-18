import Foundation

/// User choices are stored separately from the executable TOML declaration.
public struct WorkflowOutputState: Codable, Sendable, Equatable {
  public var format = "rill.workflow-state"
  public var version = 1
  public var workflowID: UUID
  public var outputs: [String: Bool]

  enum CodingKeys: String, CodingKey { case format, version, workflowID = "workflow_id", outputs }
  public init(workflowID: UUID, outputs: [String: Bool] = [:]) {
    self.workflowID = workflowID
    self.outputs = outputs
  }
  public func validate(for workflow: WorkflowDefinition) throws {
    guard format == "rill.workflow-state", version == 1, workflowID == workflow.id else {
      throw WorkflowDocumentError("state", "The output state format or workflow identity does not match.")
    }
    var actions: [String: OutputActionReference] = [:]
    for (index, action) in workflow.plan.output.actions.enumerated() {
      let id = action.documentID ?? "output-\(index + 1)"
      guard actions.updateValue(action, forKey: id) == nil else { throw WorkflowDocumentError("state.outputs", "Duplicate output identity.") }
    }
    for (id, enabled) in outputs {
      guard let action = actions[id] else { throw WorkflowDocumentError("state.outputs.\(id)", "Unknown output ID.") }
      guard enabled || action.optional else {
        throw WorkflowDocumentError("state.outputs.\(id)", "Automatic outputs cannot be disabled.")
      }
    }
  }
  public func isEnabled(_ action: OutputActionReference, index: Int) -> Bool {
    !action.optional || outputs[action.documentID ?? "output-\(index + 1)"] != false
  }
  public func applying(to workflow: WorkflowDefinition) throws -> WorkflowDefinition {
    try validate(for: workflow)
    var resolved = workflow
    resolved.plan.output.actions = workflow.plan.output.actions.enumerated().compactMap {
      isEnabled($0.element, index: $0.offset) ? $0.element : nil
    }
    return resolved
  }
}
