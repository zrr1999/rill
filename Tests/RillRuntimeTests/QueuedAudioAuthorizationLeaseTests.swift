import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor LeaseValidationBarrier {
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var validationCount = 0

    func hold() async {
        validationCount += 1
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func count() -> Int { validationCount }
}

private actor LeaseSettingsStore {
    private var settings: PrivacyPolicySettings

    init(_ settings: PrivacyPolicySettings) {
        self.settings = settings
    }

    func read() -> PrivacyPolicySettings { settings }

    func replace(with settings: PrivacyPolicySettings) {
        self.settings = settings
    }
}

private actor LeaseConfirmationProbe {
    private var count = 0

    func confirm() -> Bool {
        count += 1
        return true
    }

    func snapshot() -> Int { count }
}

final class QueuedAudioAuthorizationLeaseTests: XCTestCase {
    func testLeasePreservesIssuedRunAndWorkflowAndRejectsMismatchedTrigger() async throws {
        let runID = UUID()
        var workflow = makeLeaseWorkflow()
        let gate = makeLeaseGate()
        let lease = try await issueLease(
            gate: gate,
            runID: runID,
            workflow: workflow
        )
        workflow.pipeline.recognizerID = "remote.speech"

        let claim = try await lease.claim(
            triggerEvent: WorkflowTriggerEvent(
                binding: .hotkey,
                workflowID: lease.workflow.id,
                sourceID: "lease-test"
            )
        )
        let consumed = try await claim.finalize()

        XCTAssertEqual(consumed.runID, runID)
        XCTAssertEqual(consumed.authorizedContext.workflow.pipeline.recognizerID, "sherpa-onnx.local")

        let mismatchedLease = try await issueLease(
            gate: gate,
            runID: UUID(),
            workflow: makeLeaseWorkflow()
        )
        do {
            _ = try await mismatchedLease.claim(
                triggerEvent: WorkflowTriggerEvent(
                    binding: .manual,
                    workflowID: UUID(),
                    sourceID: "mismatched-workflow"
                )
            )
            XCTFail("A trigger for another workflow must not consume the lease successfully.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .audioProcessingAuthorizationInvalid)
        }
    }

    func testLeaseAllowsOnlyOneConcurrentClaim() async throws {
        let runID = UUID()
        let workflow = makeLeaseWorkflow()
        let context = makeLeaseContext()
        let barrier = LeaseValidationBarrier()
        let payload = AuthorizedAudioProcessingLease.Payload(
            runID: runID,
            workflow: workflow,
            sourcePrivacyContext: context,
            authorizedContext: context,
            recognitionOptions: .empty,
            policySettings: PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            ),
            decision: PrivacyPolicyDecision(),
            processingDestinations: [.localSpeech]
        )
        let lease = AuthorizedAudioProcessingLease(
            payload: payload,
            claimValidator: { payload, _ in
                await barrier.hold()
                return AuthorizedAudioProcessingClaim.PolicyState(
                    settings: payload.policySettings,
                    decision: payload.decision,
                    processingDestinations: payload.processingDestinations,
                    cloudConfirmationSatisfied: false
                )
            },
            finalValidator: { payload, _ in
                AuthorizedWorkflowRunContext(
                    workflow: payload.workflow,
                    contextSnapshot: payload.authorizedContext,
                    recognitionOptions: payload.recognitionOptions
                )
            }
        )

        let first = Task {
            try await lease.claim(triggerEvent: nil)
        }
        await barrier.waitUntilEntered()

        do {
            _ = try await lease.claim(triggerEvent: nil)
            XCTFail("The second concurrent consumer must be rejected.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .audioProcessingAuthorizationAlreadyConsumed)
        }

        await barrier.release()
        let firstClaim = try await first.value
        let firstResult = try await firstClaim.finalize()
        let validationCount = await barrier.count()
        XCTAssertEqual(firstResult.runID, runID)
        XCTAssertEqual(validationCount, 1)
    }

    func testLeaseIssuanceRejectsPolicyChangeWhileRecognitionOptionsAreResolved() async {
        let initialSettings = PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: false
        )
        let settings = LeaseSettingsStore(initialSettings)
        let optionsBarrier = LeaseValidationBarrier()
        let gate = PrivacyRunGate(
            settingsProvider: { await settings.read() },
            cloudConfirmationProvider: { _, _, _ in false }
        )
        let workflow = makeLeaseWorkflow()
        let context = makeLeaseContext()
        let issuance = Task {
            try await gate.issueAudioProcessingLease(
                runID: UUID(),
                privacyContextProvider: { context },
                contextProvider: { decision in context.applying(decision) },
                recognitionOptionsProvider: { _, _ in
                    await optionsBarrier.hold()
                    return .empty
                },
                workflow: workflow
            )
        }
        await optionsBarrier.waitUntilEntered()
        await settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.apple.Notes",
                    applicationName: "Notes"
                ),
            ],
            cloudConfirmationRequired: false
        ))
        await optionsBarrier.release()

        do {
            _ = try await issuance.value
            XCTFail("Policy drift while options are resolved must block lease issuance.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .policyChangedDuringAuthorization)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFinalizationRequestsOnlyOneNewCloudConfirmation() async throws {
        let settings = LeaseSettingsStore(
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )
        let confirmation = LeaseConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: { await settings.read() },
            cloudConfirmationProvider: { _, _, _ in await confirmation.confirm() }
        )
        let lease = try await issueLease(
            gate: gate,
            runID: UUID(),
            workflow: makeCloudLeaseWorkflow()
        )
        let claim = try await lease.claim(triggerEvent: nil)

        await settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: true
        ))
        _ = try await claim.finalize()

        do {
            _ = try await claim.finalize()
            XCTFail("A finalized processing claim must not be replayed.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .audioProcessingAuthorizationAlreadyConsumed)
        }
        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 1)
    }

    func testIssuanceConfirmationIsNotRepeatedByClaimOrFinalization() async throws {
        let confirmation = LeaseConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: true
                )
            },
            cloudConfirmationProvider: { _, _, _ in await confirmation.confirm() }
        )
        let lease = try await issueLease(
            gate: gate,
            runID: UUID(),
            workflow: makeCloudLeaseWorkflow()
        )

        let claim = try await lease.claim(triggerEvent: nil)
        _ = try await claim.finalize()

        let confirmationCount = await confirmation.snapshot()
        XCTAssertEqual(confirmationCount, 1)
    }
}

private func makeLeaseGate() -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: {
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        },
        cloudConfirmationProvider: { _, _, _ in
            XCTFail("The local lease must not request cloud confirmation.")
            return false
        }
    )
}

private func issueLease(
    gate: PrivacyRunGate,
    runID: UUID,
    workflow: WorkflowDefinition
) async throws -> AuthorizedAudioProcessingLease {
    let context = makeLeaseContext()
    return try await gate.issueAudioProcessingLease(
        runID: runID,
        privacyContextProvider: { context },
        contextProvider: { decision in context.applying(decision) },
        recognitionOptionsProvider: { _, _ in .empty },
        workflow: workflow
    )
}

private func makeLeaseWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Queued Lease",
        trigger: .hotkey,
        pipeline: PipelineDeclaration(
            recognizerID: "sherpa-onnx.local",
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
}

private func makeCloudLeaseWorkflow() -> WorkflowDefinition {
    var workflow = makeLeaseWorkflow()
    workflow.pipeline.postProcessSteps = [
        PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")
    ]
    return workflow
}

private func makeLeaseContext() -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 42,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 1)
    )
}
