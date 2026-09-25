import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private struct RegressionContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private actor RegressionActionProbe {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private struct RegressionProbeAction: OutputAction {
    let id = "regression.action"
    let probe: RegressionActionProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        let text = try record.requireText(for: id)
        await probe.record(text)
        return .skipped("captured")
    }
}

private struct RegressionRecognizer: SpeechRecognizer {
    let id = "regression.recognizer"
    let text: String

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        RecognitionResult(rawText: text, bestText: text)
    }
}

private actor StageBlockingDiagnosticRepository: DiagnosticRepository {
    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration { .initial }
    func save(_ value: DiagnosticEvent, generation: RunHistoryWriteGeneration) async throws {
        guard generation == .initial else { throw RunHistoryGenerationError.unsupported }
        try await (self as any DiagnosticRepository).save(value)
    }

    private let blockedStage: String
    private var observedBlockedStage = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var storedEvents: [DiagnosticEvent] = []

    init(blockedStage: WorkflowRunStage) {
        self.blockedStage = blockedStage.rawValue
    }

    func save(_ event: DiagnosticEvent) async throws {
        storedEvents.append(event)
        guard
            !observedBlockedStage,
            event.event == "session.stage",
            event.metadata["stage"] == blockedStage
        else {
            return
        }

        observedBlockedStage = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !observedBlockedStage else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        storedEvents.filter { event in
            if let runID = query.runID, event.runID != runID {
                return false
            }
            if let subsystem = query.subsystem, event.subsystem != subsystem {
                return false
            }
            if let minimumLevel = query.minimumLevel, event.level.severity < minimumLevel.severity {
                return false
            }
            if let since = query.since, event.timestamp < since {
                return false
            }
            return true
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DeferredAudioGate {
    private var didBlock = false
    private var observedBlock = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIfNeeded() async {
        guard !didBlock else { return }
        didBlock = true
        observedBlock = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !observedBlock else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private func makeRegressionWorkflow(
    name: String,
    recognizerID: String = "regression.recognizer",
    actionID: String = "regression.action"
) -> WorkflowDefinition {
    WorkflowDefinition(
        name: name,
        pipeline: PipelineDeclaration(
            recognizerID: recognizerID,
            outputActions: [OutputActionReference(id: actionID)]
        ),
        ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
    )
}

private func makeCapturedAudio(_ pathComponent: String) throws -> CapturedAudio {
    try CapturedAudio(
        durationSeconds: 1.0,
        format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
        fileURL: URL(fileURLWithPath: "/tmp/\(pathComponent).caf")
    )
}

final class RuntimeCoordinationRegressionTests: XCTestCase {
    func testCoordinatorRemainsBusyUntilFailedTerminalStageFinishes() async throws {
        let eventBus = EventBus()
        let repository = StageBlockingDiagnosticRepository(blockedStage: .failed)
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus, repository: repository)
        let resolver = CandidateResolver(eventBus: eventBus, diagnostics: diagnostics)
        let actionProbe = RegressionActionProbe()
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [RegressionRecognizer(text: "second run")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RegressionProbeAction(probe: actionProbe)]),
            candidateResolver: resolver,
            eventBus: eventBus,
            diagnostics: diagnostics
        )

        let failingWorkflow = makeRegressionWorkflow(
            name: "Missing Recognizer",
            recognizerID: "missing.recognizer"
        )
        let succeedingWorkflow = makeRegressionWorkflow(name: "Second Run")

        let firstRun = Task {
            await coordinator.run(workflow: failingWorkflow, contextSnapshot: .empty)
        }
        await repository.waitUntilBlocked()

        let stateWhileFailureIsPublishing = await coordinator.currentState()
        if case .idle = stateWhileFailureIsPublishing {
            XCTFail("Coordinator exposed idle before failed terminal bookkeeping finished.")
        }

        let secondRun = Task {
            await coordinator.run(workflow: succeedingWorkflow, contextSnapshot: .empty)
        }

        for _ in 0..<20 {
            await Task.yield()
        }
        let probeValuesWhileFirstRunBlocked = await actionProbe.snapshot()
        XCTAssertEqual(probeValuesWhileFirstRunBlocked, [])

        await repository.resume()
        await firstRun.value
        await secondRun.value

        let finalProbeValues = await actionProbe.snapshot()
        XCTAssertEqual(finalProbeValues, [])
    }

    func testCapturedAudioProcessingQueueKeepsLaterJobsQueuedBehindBlockedActiveJob() async throws {
        let eventBus = EventBus()
        let actionProbe = RegressionActionProbe()
        let resolver = CandidateResolver(eventBus: eventBus)
        let coordinator = SessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [RegressionRecognizer(text: "queued text")]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: [RegressionProbeAction(probe: actionProbe)]),
            candidateResolver: resolver,
            eventBus: eventBus
        )
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let gate = DeferredAudioGate()
        let workflow = makeRegressionWorkflow(name: "Queued Workflow")
        let firstRunID = UUID()
        let secondRunID = UUID()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: firstRunID,
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: DeferredCapturedAudio(
                task: Task {
                    await gate.waitIfNeeded()
                    return try makeCapturedAudio("rill-regression-first")
                }
            )
        )
        await gate.waitUntilBlocked()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: secondRunID,
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(try makeCapturedAudio("rill-regression-second"))
        )

        let queuedSnapshot = await queue.snapshot()
        XCTAssertEqual(queuedSnapshot.processingRunID, firstRunID)
        XCTAssertEqual(queuedSnapshot.pendingCount, 2)
        XCTAssertEqual(queuedSnapshot.queuedCount, 1)
        let probeValuesBeforeRelease = await actionProbe.snapshot()
        XCTAssertEqual(probeValuesBeforeRelease, [])

        await gate.resume()

        var deliveredValues: [String] = []
        for _ in 0..<40 {
            deliveredValues = await actionProbe.snapshot()
            if deliveredValues.count == 2 {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(deliveredValues, ["queued text", "queued text"])

        let drainedSnapshot = await queue.snapshot()
        XCTAssertNil(drainedSnapshot.processingRunID)
        XCTAssertEqual(drainedSnapshot.pendingCount, 0)
    }
}
