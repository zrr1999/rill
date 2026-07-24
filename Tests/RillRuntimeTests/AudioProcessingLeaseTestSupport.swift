import Foundation
@testable import RillCore
@testable import RillRuntime

func makeAudioProcessingTestLease(
    runID: UUID,
    workflow: WorkflowDefinition,
    context: ContextSnapshot = .empty,
    recognitionOptions: SpeechRecognitionRequestOptions = .empty
) -> AuthorizedAudioProcessingLease {
    let payload = AuthorizedAudioProcessingLease.Payload(
        runID: runID,
        workflow: workflow,
        sourcePrivacyContext: context,
        authorizedContext: context,
        recognitionOptions: recognitionOptions,
        policySettings: PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: false
        ),
        decision: PrivacyPolicyDecision(),
        processingDestinations: []
    )
    return AuthorizedAudioProcessingLease(
        payload: payload,
        claimValidator: { payload, triggerEvent in
            guard triggerEvent?.workflowID == nil || triggerEvent?.workflowID == payload.workflow.id else {
                throw PrivacyRunGate.GateError.audioProcessingAuthorizationInvalid
            }
            return AuthorizedAudioProcessingClaim.PolicyState(
                settings: payload.policySettings,
                decision: payload.decision,
                processingDestinations: payload.processingDestinations,
                cloudConfirmationSatisfied: false
            )
        },
        finalValidator: { payload, _ in
            return AuthorizedWorkflowRunContext(
                workflow: payload.workflow,
                contextSnapshot: payload.authorizedContext,
                recognitionOptions: payload.recognitionOptions
            )
        }
    )
}
