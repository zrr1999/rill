import RillKnowledge
import RillCore

private actor WorkflowRunAuthorizationConsumption {
    private var wasConsumed = false

    func consume() throws {
        guard !wasConsumed else {
            throw PrivacyRunGate.GateError.workflowRunAuthorizationAlreadyConsumed
        }
        wasConsumed = true
    }
}

/// The redacted context and derived recognition options produced after the
/// current workflow crosses the privacy authorization boundary.
///
/// Copies share one consumption state. A context therefore authorizes exactly
/// one coordinator entry even when a caller copies it or submits it
/// concurrently. It is not serializable and cannot be refreshed or reset.
public struct AuthorizedWorkflowRunContext: Sendable {
    let workflow: WorkflowDefinition
    let contextSnapshot: ContextSnapshot
    let recognitionOptions: SpeechRecognitionRequestOptions
    let invocation: WorkflowRunInvocation
    let contextPreparation: RunContextPreparation?
    private let consumption = WorkflowRunAuthorizationConsumption()

    init(
        workflow: WorkflowDefinition,
        contextSnapshot: ContextSnapshot,
        recognitionOptions: SpeechRecognitionRequestOptions,
        invocation: WorkflowRunInvocation = .capture,
        contextPreparation: RunContextPreparation? = nil
    ) {
        self.workflow = workflow
        self.contextSnapshot = contextSnapshot
        self.recognitionOptions = recognitionOptions
        self.invocation = invocation
        self.contextPreparation = contextPreparation
    }

    func consume() async throws {
        try await consumption.consume()
    }
}
