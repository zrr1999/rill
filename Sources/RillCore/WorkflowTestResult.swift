import Foundation

/// Ephemeral editor results. These values are deliberately not serializable.
public struct WorkflowTestStepResult: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var kind: WorkflowProcessStepKind
    public var input: String
    public var output: String
    public var branch: Bool?
    public var error: String?

    public init(
        id: UUID, kind: WorkflowProcessStepKind, input: String, output: String, branch: Bool? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.input = input
        self.output = output
        self.branch = branch
        self.error = error
    }
}
