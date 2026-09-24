
@testable import RillCore
@testable import RillWorkflows
import XCTest

private actor LiveContextStore {
    private var value: ContextSnapshot

    init(_ value: ContextSnapshot) {
        self.value = value
    }

    func read() -> ContextSnapshot { value }
    func replace(_ value: ContextSnapshot) { self.value = value }
}

private actor LiveSettingsStore {
    enum State {
        case available(PrivacyPolicySettings)
        case unavailable
    }

    private var state: State

    init(_ settings: PrivacyPolicySettings) {
        state = .available(settings)
    }

    func read() throws -> PrivacyPolicySettings {
        switch state {
        case .available(let settings):
            return settings
        case .unavailable:
            throw PrivacyPolicySettingsSourceError.notReady
        }
    }

    func replace(_ settings: PrivacyPolicySettings) {
        state = .available(settings)
    }

    func markUnavailable() {
        state = .unavailable
    }
}

private actor LiveRevocationProbe {
    private var calls: [(UUID, LiveAudioAuthorizationRevocationReason)] = []

    func record(_ runID: UUID, _ reason: LiveAudioAuthorizationRevocationReason) {
        calls.append((runID, reason))
    }

    func snapshot() -> [(UUID, LiveAudioAuthorizationRevocationReason)] { calls }
}

private actor LiveConfirmationProbe {
    private var count = 0

    func record() { count += 1 }
    func snapshot() -> Int { count }
}

final class AuthorizedLiveAudioSessionTests: XCTestCase {
    func testCaptureCannotSealBeforePrivacyMonitorStarts() async throws {
        let fixture = try await makeFixture()

        do {
            try await fixture.session.sealCapture()
            XCTFail("A live capture must start continuous authorization before sealing.")
        } catch let error as LiveAudioSessionError {
            XCTAssertEqual(error, .monitorNotStarted)
        }
        await fixture.session.cancel()
    }

    func testAllowedApplicationChangeKeepsCloudTextSessionActive() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()

        await fixture.contexts.replace(makeLiveContext(bundleIdentifier: "com.apple.TextEdit"))
        try await Task.sleep(for: .milliseconds(35))

        XCTAssertTrue(fixture.session.audioLifetime.isActive)
        let revocations = await fixture.revocations.snapshot()
        XCTAssertTrue(revocations.isEmpty)
        await fixture.session.cancel()
    }

    func testSensitiveApplicationRevokesAndNotifiesExactlyOnce() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()

        await fixture.contexts.replace(makeLiveContext(bundleIdentifier: "com.1password.1password"))
        await waitUntil {
            fixture.session.audioLifetime.state
                == .revoked(.authorizationInvalidated)
        }
        try await Task.sleep(for: .milliseconds(20))

        let calls = await fixture.revocations.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, fixture.runID)
        XCTAssertEqual(calls.first?.1, .contextRestricted)
    }

    func testUnknownFocusAndUnavailableSettingsFailClosed() async throws {
        let unknownFixture = try await makeFixture()
        try await unknownFixture.session.startMonitoring()
        await unknownFixture.contexts.replace(.empty)
        await waitUntil { !unknownFixture.session.audioLifetime.isActive }
        let unknownRevocation = await unknownFixture.revocations.snapshot().first?.1
        XCTAssertEqual(unknownRevocation, .contextRestricted)

        let unavailableFixture = try await makeFixture()
        try await unavailableFixture.session.startMonitoring()
        await unavailableFixture.settings.markUnavailable()
        await waitUntil { !unavailableFixture.session.audioLifetime.isActive }
        let unavailableRevocation = await unavailableFixture.revocations.snapshot().first?.1
        XCTAssertEqual(unavailableRevocation, .privacySettingsUnavailable)
    }

    func testNewCloudConfirmationRequirementRevokesWithoutPromptingMidRun() async throws {
        let initialSettings = PrivacyPolicySettings(
            sensitiveAppRules: SensitiveAppRule.recommendedDefaults,
            cloudConfirmationRequired: false
        )
        let fixture = try await makeFixture(settings: initialSettings)
        try await fixture.session.startMonitoring()
        var confirmationCount = await fixture.confirmations.snapshot()
        XCTAssertEqual(confirmationCount, 0)

        await fixture.settings.replace(PrivacyPolicySettings(
            sensitiveAppRules: SensitiveAppRule.recommendedDefaults,
            cloudConfirmationRequired: true
        ))
        await waitUntil { !fixture.session.audioLifetime.isActive }

        confirmationCount = await fixture.confirmations.snapshot()
        let revocation = await fixture.revocations.snapshot().first?.1
        XCTAssertEqual(confirmationCount, 0)
        XCTAssertEqual(revocation, .cloudConfirmationRequired)
    }

    func testSealFreezesStoppedInputAndLeaseCompletesLifetimeAfterFinalization() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()
        try await fixture.session.sealCapture()
        let lease = try await fixture.session.processingLeaseForEnqueue()
        XCTAssertTrue(lease.acceptQueueOwnership())

        await fixture.contexts.replace(makeLiveContext(bundleIdentifier: "com.1password.1password"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.session.audioLifetime.isActive)
        let revocations = await fixture.revocations.snapshot()
        XCTAssertTrue(revocations.isEmpty)

        let claim = try await lease.claim(
            triggerEvent: WorkflowTriggerEvent(
                binding: .manual,
                workflowID: fixture.workflow.id,
                sourceID: "test.live"
            )
        )
        _ = try await claim.finalize()

        XCTAssertEqual(fixture.session.audioLifetime.state, .completed)
    }

    func testProcessingLeaseCannotEscapeBeforeSeal() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()

        do {
            _ = try await fixture.session.processingLeaseForEnqueue()
            XCTFail("An unsealed live capture must not expose its processing lease.")
        } catch let error as LiveAudioSessionError {
            XCTAssertEqual(error, .captureNotSealed)
        }
        await fixture.session.cancel()
    }

    func testRevokedLifetimeCannotUseSealedLeaseForPrerecordedFallback() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()
        try await fixture.session.sealCapture()
        let lease = try await fixture.session.processingLeaseForEnqueue()
        XCTAssertTrue(lease.acceptQueueOwnership())
        _ = fixture.session.audioLifetime.revoke(.serviceFailure)

        do {
            _ = try await lease.claim(
                triggerEvent: WorkflowTriggerEvent(
                    binding: .manual,
                    workflowID: fixture.workflow.id,
                    sourceID: "test.live-fallback"
                )
            )
            XCTFail("A revoked live capture must not fall back to prerecorded upload.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .audioProcessingAuthorizationInvalid)
        }
    }

    func testControllerCancellationBeforeQueueTransferRejectsLeaseOwnership() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()
        try await fixture.session.sealCapture()
        let lease = try await fixture.session.processingLeaseForEnqueue()

        let result = await fixture.session.cancel()

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(lease.acceptQueueOwnership())
        XCTAssertEqual(
            fixture.session.audioLifetime.state,
            .revoked(.captureCancelled)
        )
    }

    func testControllerCancellationAfterTransferLeavesCancellationToQueue() async throws {
        let fixture = try await makeFixture()
        try await fixture.session.startMonitoring()
        try await fixture.session.sealCapture()
        let lease = try await fixture.session.processingLeaseForEnqueue()
        XCTAssertTrue(lease.acceptQueueOwnership())

        let result = await fixture.session.cancel()

        XCTAssertEqual(result, .queueOwned)
        XCTAssertTrue(fixture.session.audioLifetime.isActive)
        lease.cancel()
        XCTAssertEqual(
            fixture.session.audioLifetime.state,
            .revoked(.captureCancelled)
        )
    }

    private struct Fixture {
        let runID: UUID
        let workflow: WorkflowDefinition
        let contexts: LiveContextStore
        let settings: LiveSettingsStore
        let confirmations: LiveConfirmationProbe
        let revocations: LiveRevocationProbe
        let session: AuthorizedLiveAudioSession
    }

    private func makeFixture(
        settings initialSettings: PrivacyPolicySettings = .defaults
    ) async throws -> Fixture {
        let runID = UUID()
        let workflow = makeLiveWorkflow()
        let contexts = LiveContextStore(makeLiveContext())
        let settings = LiveSettingsStore(initialSettings)
        let confirmations = LiveConfirmationProbe()
        let revocations = LiveRevocationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: { try await settings.read() },
            cloudConfirmationProvider: { _, _, _ in
                await confirmations.record()
                return true
            }
        )
        let session = try await gate.issueLiveAudioSession(
            runID: runID,
            privacyContextProvider: { await contexts.read() },
            contextProvider: { _ in await contexts.read() },
            recognitionOptionsProvider: { _, _ in .empty },
            workflow: workflow,
            monitorInterval: .milliseconds(5),
            revocationHandler: { runID, reason in
                await revocations.record(runID, reason)
            }
        )
        return Fixture(
            runID: runID,
            workflow: workflow,
            contexts: contexts,
            settings: settings,
            confirmations: confirmations,
            revocations: revocations,
            session: session
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        _ predicate: () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The live authorization state did not change in time.")
    }
}

private func makeLiveContext(
    bundleIdentifier: String = "com.apple.Notes"
) -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Live Test",
            bundleIdentifier: bundleIdentifier,
            processIdentifier: 42,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 1)
    )
}

private func makeLiveWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
        name: "Live Cloud Text Test",
        trigger: .manual,
        pipeline: PipelineDeclaration(
            recognizerID: "sherpa-onnx.local",
            postProcessSteps: [
                PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")
            ],
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
}
