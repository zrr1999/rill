import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor MutableQueuedPrivacySettings {
    enum State: Sendable {
        case settings(PrivacyPolicySettings)
        case unavailable
    }

    struct Unavailable: Error {}

    private var state: State
    private var readCount = 0

    init(_ settings: PrivacyPolicySettings) {
        state = .settings(settings)
    }

    func read() throws -> PrivacyPolicySettings {
        readCount += 1
        switch state {
        case .settings(let settings): return settings
        case .unavailable: throw Unavailable()
        }
    }

    func replace(with settings: PrivacyPolicySettings) {
        state = .settings(settings)
    }

    func fail() {
        state = .unavailable
    }

    func reads() -> Int { readCount }
}

private actor DeferredFinalizationBarrier {
    private let capturedAudio: CapturedAudio
    private var isReleased = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(capturedAudio: CapturedAudio) {
        self.capturedAudio = capturedAudio
    }

    func resolve() async -> CapturedAudio {
        if isReleased { return capturedAudio }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
        return capturedAudio
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor QueuedRecoveryStoreProbe: FailedAudioRecoveryStore {
    private var preserveCount = 0

    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt {
        preserveCount += 1
        return FailedAudioRecoveryReceipt(
            originalRunID: originalRunID,
            workflowID: workflowID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            durationSeconds: audio.durationSeconds,
            format: audio.format,
            plaintextByteCount: 1,
            failureStage: failure.stage,
            failureCode: failure.code
        )
    }

    func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt] { [] }
    func materializeForRetry(id: UUID, attemptID: UUID, now: Date) async throws -> CapturedAudio {
        throw FailedAudioRecoveryError.notFound
    }
    func restoreAfterFailedRetry(id: UUID, attemptID: UUID) async throws {}
    func delete(id: UUID) async throws {}
    func deleteAll() async throws {}
    func purgeExpired(now: Date) async throws -> Int { 0 }

    func preservedCount() -> Int { preserveCount }
}

private actor QueuedConfirmationProbe {
    struct Call: Sendable, Equatable {
        let workflowID: UUID
        let destinations: [PrivacyProcessingDestination]
    }

    private var calls: [Call] = []

    func confirm(
        workflow: WorkflowDefinition,
        destinations: [PrivacyProcessingDestination]
    ) -> Bool {
        calls.append(Call(workflowID: workflow.id, destinations: destinations))
        return true
    }

    func snapshot() -> [Call] { calls }
}

private actor QueuedRecognitionBarrier {
    private let blockedRunID: UUID
    private var requests: [RecognitionRequest] = []
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(blockedRunID: UUID) {
        self.blockedRunID = blockedRunID
    }

    func recognize(_ request: RecognitionRequest) async -> RecognitionResult {
        requests.append(request)
        if request.runID == blockedRunID {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return RecognitionResult(rawText: "queued", bestText: "queued")
    }

    func waitUntilFirstRequestIsBlocked() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func snapshot() -> [RecognitionRequest] { requests }
}

private struct QueuedPolicyRecognizer: SpeechRecognizer {
    let id: String
    let barrier: QueuedRecognitionBarrier
    let capabilities = SpeechRecognizerCapabilities(supportedHintKinds: [.keyterm])

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await barrier.recognize(request)
    }
}

private struct QueuedWhitespaceRecognizer: SpeechRecognizer {
    let id: String

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        RecognitionResult(rawText: " \n\t ", bestText: " \n\t ")
    }
}

private struct QueuedNoopAction: OutputAction {
    let id = "stack.push"

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        .skipped("queue-policy-test")
    }
}

private struct QueuedCloudTextTransformer: TextTransformer {
    let id = "queued.cloud-text"
    let supportedKinds: [PostProcessStepKind] = [.llmRewrite]

    func transform(
        text: String,
        step: PostProcessStep,
        context: TransformContext
    ) async throws -> String {
        text
    }
}

private actor QueuedCleanupProbe {
    private var count = 0

    func cleanup(_: CapturedAudio) {
        count += 1
    }

    func snapshot() -> Int { count }
}

private struct QueuedTransientRemovalError: Error {}

private actor QueuedTransientRemovalProbe {
    private var attemptCount = 0

    func remove(_ capturedAudio: CapturedAudio) throws {
        attemptCount += 1
        if attemptCount == 1 {
            throw QueuedTransientRemovalError()
        }
        _ = try capturedAudio.removeManagedTemporaryFile()
    }

    func attempts() -> Int { attemptCount }
}

private actor QueuedEventProbe {
    private var events: [RillEvent] = []

    func record(_ event: RillEvent) {
        events.append(event)
    }

    func snapshot() -> [RillEvent] { events }
}

private struct QueuedPolicyFixture {
    let queue: CapturedAudioProcessingQueue
    let settings: MutableQueuedPrivacySettings
    let confirmation: QueuedConfirmationProbe
    let recognition: QueuedRecognitionBarrier
    let cleanup: QueuedCleanupProbe
    let events: QueuedEventProbe
    let eventTask: Task<Void, Never>
    let firstRunID: UUID
    let secondRunID: UUID
    let cloudWorkflow: WorkflowDefinition
}

final class QueuedAudioPolicyRevalidationTests: XCTestCase {
    func testNoSpeechFailureDoesNotRetainQueuedAudioForRecovery() async throws {
        let runID = UUID()
        let workflow = queuedWorkflow(
            name: "Queued no speech",
            recognizerID: "whitespace.recognizer"
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-no-speech-\(UUID().uuidString).wav")
        try Data([0, 1, 2]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 0.2,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let eventBus = EventBus()
        let coordinator = SessionCoordinator(
            contextProvider: QueuedPolicyContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [QueuedWhitespaceRecognizer(id: "whitespace.recognizer")]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [QueuedCloudTextTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [QueuedNoopAction()]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let recoveryStore = QueuedRecoveryStoreProbe()
        let recoveryController = FailedAudioRecoveryController(
            store: recoveryStore,
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        try await recoveryController.refresh(isEnabled: true)
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            failedAudioRecoveryController: recoveryController
        )

        let transfer = await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: runID,
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(capturedAudio)
        )
        await waitUntilQueueDrains(queue)

        let preservedCount = await recoveryStore.preservedCount()
        let pendingCount = await queue.pendingCount
        XCTAssertEqual(transfer, .accepted)
        XCTAssertEqual(preservedCount, 0)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        await queue.shutdown()
        await recoveryController.stopForApplicationShutdown()
    }

    func testPolicyTighteningDuringDeferredFinalizationRetriesTransientRemovalWithoutEgress() async throws {
        let runID = UUID()
        let context = queuedPrivacyContext()
        let settings = MutableQueuedPrivacySettings(
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )
        let confirmation = QueuedConfirmationProbe()
        let gate = PrivacyRunGate(
            settingsProvider: { try await settings.read() },
            cloudConfirmationProvider: { workflow, _, destinations in
                await confirmation.confirm(workflow: workflow, destinations: destinations)
            }
        )
        let workflow = queuedWorkflow(
            name: "Deferred cloud fallback",
            recognizerID: "remote.speech"
        )
        let lease = try await gate.issueAudioProcessingLease(
            runID: runID,
            privacyContextProvider: { context },
            contextProvider: { decision in context.applying(decision) },
            recognitionOptionsProvider: { _, _ in .empty },
            workflow: workflow
        )
        let issuanceReadCount = await settings.reads()

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-deferred-finalization-\(UUID().uuidString).wav")
        try Data([0, 1, 2]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 0.1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let finalization = DeferredFinalizationBarrier(capturedAudio: capturedAudio)

        let eventBus = EventBus()
        let recognition = QueuedRecognitionBarrier(blockedRunID: UUID())
        let coordinator = SessionCoordinator(
            contextProvider: QueuedPolicyContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    QueuedPolicyRecognizer(id: "sherpa-onnx.local", barrier: recognition),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(
                transformers: [QueuedCloudTextTransformer()]
            ),
            actionRegistry: OutputActionRegistry(actions: [QueuedNoopAction()]),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            deliveryStack: DeliveryStack(eventBus: eventBus),
            eventBus: eventBus
        )
        let recoveryStore = QueuedRecoveryStoreProbe()
        let recoveryController = FailedAudioRecoveryController(
            store: recoveryStore,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            privacyRunGate: gate
        )
        try await recoveryController.refresh(isEnabled: true)
        let removal = QueuedTransientRemovalProbe()
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            failedAudioRecoveryController: recoveryController,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await removal.remove(capturedAudio)
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(1),
            rejectedCleanupMaximumRetryDelay: .milliseconds(2),
            rejectedCleanupSleep: { _ in }
        )
        let events = QueuedEventProbe()
        let stream = await eventBus.stream()
        let eventTask = Task {
            for await event in stream {
                await events.record(event)
            }
        }
        defer { eventTask.cancel() }

        await queue.enqueue(
            authorizationLease: lease,
            triggerEvent: WorkflowTriggerEvent(
                binding: .hotkey,
                workflowID: workflow.id,
                sourceID: "deferred-finalization"
            ),
            deferredCapture: DeferredCapturedAudio(
                task: Task<CapturedAudio, Error> { await finalization.resolve() }
            )
        )
        let claimWasValidated = await waitUntilSettingsReadCountExceeds(
            issuanceReadCount,
            settings: settings
        )
        XCTAssertTrue(claimWasValidated)
        await settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.example.notes",
                    applicationName: "Notes"
                ),
            ],
            cloudConfirmationRequired: false
        ))
        await finalization.release()
        await waitUntilQueueDrains(queue)
        await waitUntilRejectedCleanupFinishes(queue)

        let requests = await recognition.snapshot()
        let preservedCount = await recoveryStore.preservedCount()
        let removalAttempts = await removal.attempts()
        let rejectedCleanupCount = await queue.rejectedCleanupCount
        let failures = await queuedFailures(from: events, runID: runID)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(preservedCount, 0)
        XCTAssertEqual(removalAttempts, 2)
        XCTAssertEqual(rejectedCleanupCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(
            failures.first?.message,
            PrivacyRunGate.GateError.cloudProcessingBlocked.localizedDescription
        )
    }

    func testQueuedCloudAudioIsBlockedWhenPolicyTightensBeforeLeaseConsumption() async throws {
        let fixture = try await makeQueuedPolicyFixture()
        defer { fixture.eventTask.cancel() }

        await fixture.settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.example.notes",
                    applicationName: "Notes"
                ),
            ],
            cloudConfirmationRequired: false
        ))
        await fixture.recognition.release()
        await waitUntilQueueDrains(fixture.queue)
        await waitUntilCleanupRuns(fixture.cleanup)

        let requests = await fixture.recognition.snapshot()
        let confirmations = await fixture.confirmation.snapshot()
        let cleanupCount = await fixture.cleanup.snapshot()
        let failures = await queuedFailures(from: fixture.events, runID: fixture.secondRunID)
        XCTAssertEqual(requests.map(\.runID), [fixture.firstRunID])
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(
            failures.first?.message,
            PrivacyRunGate.GateError.cloudProcessingBlocked.localizedDescription
        )
    }

    func testQueuedCloudAudioFailsClosedWhenSettingsDisappearBeforeLeaseConsumption() async throws {
        let fixture = try await makeQueuedPolicyFixture()
        defer { fixture.eventTask.cancel() }

        await fixture.settings.fail()
        await fixture.recognition.release()
        await waitUntilQueueDrains(fixture.queue)
        await waitUntilCleanupRuns(fixture.cleanup)

        let requests = await fixture.recognition.snapshot()
        let confirmations = await fixture.confirmation.snapshot()
        let cleanupCount = await fixture.cleanup.snapshot()
        let failures = await queuedFailures(from: fixture.events, runID: fixture.secondRunID)
        XCTAssertEqual(requests.map(\.runID), [fixture.firstRunID])
        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(
            failures.first?.message,
            PrivacyRunGate.GateError.settingsUnavailable.localizedDescription
        )
    }

    func testQueuedCloudAudioRequestsOneConfirmationWhenPolicyTightensOnlyConfirmation() async throws {
        let fixture = try await makeQueuedPolicyFixture()
        defer { fixture.eventTask.cancel() }

        await fixture.settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: true
        ))
        var confirmations = await fixture.confirmation.snapshot()
        XCTAssertTrue(confirmations.isEmpty)

        await fixture.recognition.release()
        await waitUntilQueueDrains(fixture.queue)

        let requests = await fixture.recognition.snapshot()
        confirmations = await fixture.confirmation.snapshot()
        let cleanupCount = await fixture.cleanup.snapshot()
        XCTAssertEqual(requests.map(\.runID), [fixture.firstRunID, fixture.secondRunID])
        XCTAssertEqual(requests.last?.options.hints.keyterms, ["capture-time-hint"])
        XCTAssertEqual(
            confirmations,
            [
                QueuedConfirmationProbe.Call(
                    workflowID: fixture.cloudWorkflow.id,
                    destinations: [.localSpeech, .cloudText]
                ),
            ]
        )
        XCTAssertEqual(cleanupCount, 0)
    }
}

private func makeQueuedPolicyFixture() async throws -> QueuedPolicyFixture {
    let firstRunID = UUID()
    let secondRunID = UUID()
    let context = queuedPrivacyContext()
    let settings = MutableQueuedPrivacySettings(
        PrivacyPolicySettings(
            sensitiveAppRules: [],
            cloudConfirmationRequired: false
        )
    )
    let confirmation = QueuedConfirmationProbe()
    let gate = PrivacyRunGate(
        settingsProvider: { try await settings.read() },
        cloudConfirmationProvider: { workflow, _, destinations in
            await confirmation.confirm(workflow: workflow, destinations: destinations)
        }
    )
    let localWorkflow = queuedWorkflow(
        name: "Blocking local",
        recognizerID: "sherpa-onnx.local"
    )
    let cloudWorkflow = queuedWorkflow(
        name: "Deferred cloud",
        recognizerID: "remote.speech"
    )
    let localLease = try await gate.issueAudioProcessingLease(
        runID: firstRunID,
        privacyContextProvider: { context },
        contextProvider: { decision in context.applying(decision) },
        recognitionOptionsProvider: { _, _ in .empty },
        workflow: localWorkflow
    )
    let cloudLease = try await gate.issueAudioProcessingLease(
        runID: secondRunID,
        privacyContextProvider: { context },
        contextProvider: { decision in context.applying(decision) },
        recognitionOptionsProvider: { _, _ in
            SpeechRecognitionRequestOptions(
                hints: RecognitionHints(keyterms: ["capture-time-hint"])
            )
        },
        workflow: cloudWorkflow
    )

    let eventBus = EventBus()
    let recognition = QueuedRecognitionBarrier(blockedRunID: firstRunID)
    let coordinator = SessionCoordinator(
        contextProvider: QueuedPolicyContextProvider(),
        recognizerRegistry: SpeechRecognizerRegistry(
            recognizers: [
                QueuedPolicyRecognizer(id: "sherpa-onnx.local", barrier: recognition),
            ]
        ),
        transformerRegistry: TextTransformerRegistry(
            transformers: [QueuedCloudTextTransformer()]
        ),
        actionRegistry: OutputActionRegistry(actions: [QueuedNoopAction()]),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        deliveryStack: DeliveryStack(eventBus: eventBus),
        eventBus: eventBus,
        vocabularyCollectionProvider: {
            [
                .personal(
                    entries: [
                        VocabularyEntry(
                            content: .hotword(phrase: "capture-time-hint")
                        ),
                    ]
                ),
            ]
        }
    )
    let cleanup = QueuedCleanupProbe()
    let queue = CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus,
        rejectedCapturedAudioRemoval: { capturedAudio in
            await cleanup.cleanup(capturedAudio)
        },
        rejectedCleanupInitialRetryDelay: .milliseconds(1),
        rejectedCleanupMaximumRetryDelay: .milliseconds(2),
        rejectedCleanupSleep: { _ in }
    )
    let events = QueuedEventProbe()
    let stream = await eventBus.stream()
    let eventTask = Task {
        for await event in stream {
            await events.record(event)
        }
    }
    let audio = try CapturedAudio(
        durationSeconds: 0.1,
        format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        inlineData: Data([0, 1])
    )

    await queue.enqueue(
        authorizationLease: localLease,
        triggerEvent: WorkflowTriggerEvent(
            binding: .hotkey,
            workflowID: localWorkflow.id,
            sourceID: "queued-policy-first"
        ),
        deferredCapture: .resolved(audio)
    )
    await recognition.waitUntilFirstRequestIsBlocked()
    await queue.enqueue(
        authorizationLease: cloudLease,
        triggerEvent: WorkflowTriggerEvent(
            binding: .hotkey,
            workflowID: cloudWorkflow.id,
            sourceID: "queued-policy-second"
        ),
        deferredCapture: .resolved(audio)
    )

    return QueuedPolicyFixture(
        queue: queue,
        settings: settings,
        confirmation: confirmation,
        recognition: recognition,
        cleanup: cleanup,
        events: events,
        eventTask: eventTask,
        firstRunID: firstRunID,
        secondRunID: secondRunID,
        cloudWorkflow: cloudWorkflow
    )
}

private struct QueuedPolicyContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private func queuedWorkflow(name: String, recognizerID: String) -> WorkflowDefinition {
    let usesCloudTextFixture = recognizerID == "remote.speech"
    var workflow = WorkflowDefinition(
        name: name,
        trigger: .hotkey,
        pipeline: PipelineDeclaration(
            recognizerID: usesCloudTextFixture ? "sherpa-onnx.local" : recognizerID,
            postProcessSteps: usesCloudTextFixture
                ? [PostProcessStep(kind: .llmRewrite, prompt: "Rewrite")]
                : [],
            outputActions: [OutputActionReference(id: "stack.push")]
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
    workflow.plan.setup.vocabularyBindings = [
        VocabularyCollectionBinding(collectionID: VocabularyCollection.personalID),
    ]
    return workflow
}

private func queuedPrivacyContext() -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Notes",
            bundleIdentifier: "com.example.notes",
            processIdentifier: 77,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: ClipboardSnapshot(plainText: "", changeCount: 1)
    )
}

private func waitUntilQueueDrains(_ queue: CapturedAudioProcessingQueue) async {
    for _ in 0..<300 {
        if await queue.pendingCount == 0 { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func waitUntilSettingsReadCountExceeds(
    _ priorCount: Int,
    settings: MutableQueuedPrivacySettings
) async -> Bool {
    for _ in 0..<300 {
        if await settings.reads() > priorCount { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

private func waitUntilRejectedCleanupFinishes(
    _ queue: CapturedAudioProcessingQueue
) async {
    for _ in 0..<300 {
        if await queue.rejectedCleanupCount == 0 { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func waitUntilCleanupRuns(_ cleanup: QueuedCleanupProbe) async {
    for _ in 0..<300 {
        if await cleanup.snapshot() > 0 { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private func queuedFailures(
    from events: QueuedEventProbe,
    runID: UUID
) async -> [(workflow: WorkflowPresentation?, message: String)] {
    for _ in 0..<100 {
        let snapshot = await events.snapshot()
        let failures: [(workflow: WorkflowPresentation?, message: String)] = snapshot.compactMap { event in
            guard case .runFailed(let eventRunID, let workflow, let message) = event,
                  eventRunID == runID else {
                return nil
            }
            return (workflow: workflow, message: message)
        }
        if !failures.isEmpty { return failures }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return []
}
