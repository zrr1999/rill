import Foundation

/// An in-memory collection of definitions validated from workflow v1 TOML resources.
public struct WorkflowManifest: Sendable, Equatable {
  public var workflows: [WorkflowDefinition]
  public init(workflows: [WorkflowDefinition]) { self.workflows = workflows }
}
