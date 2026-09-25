import Foundation
import XCTest

@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime

private struct RecordingTimingContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private struct RecordingTimingRecognizer: SpeechRecognizer {
    let id = "recording.timing-recognizer"

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        _ = request
        return RecognitionResult(rawText: "recorded", bestText: "recorded")
    }
}

private actor BlockingRecordingDiagnosticRepository: DiagnosticRepository {
    private let blockedEvent: String
    private var events: [DiagnosticEvent] = []
    private var hasEnteredBlockedSave = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockedEvent: String) {
        self.blockedEvent = blockedEvent
    }

    func save(_ event: DiagnosticEvent) async throws {
        try await save(event, generation: .initial)
    }

    func save(
        _ event: DiagnosticEvent,
        generation: RunHistoryWriteGeneration
    ) async throws {
        _ = generation
        if event.event == blockedEvent {
            hasEnteredBlockedSave = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if !isReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        events.append(event)
    }

    func events(matching query: DiagnosticQuery) async throws -> [DiagnosticEvent] {
        _ = query
        return events
    }

    func captureRunHistoryWriteGeneration() async throws -> RunHistoryWriteGeneration {
        .initial
    }

    func deleteEvents(olderThan cutoff: Date) async throws -> Int {
        let previousCount = events.count
        events.removeAll { $0.timestamp < cutoff }
        return previousCount - events.count
    }

    func deleteEvents(through upperBound: Date) async throws -> Int {
        let previousCount = events.count
        events.removeAll { $0.timestamp <= upperBound }
        return previousCount - events.count
    }

    func deleteEvents(
        obsoletedBy transition: RunHistoryClearTransition,
        preservingLegacyRowsAfter legacyUpperBound: Date?
    ) async throws -> Int {
        _ = transition
        _ = legacyUpperBound
        let removedCount = events.count
        events.removeAll()
        return removedCount
    }

    func deleteAllEvents() async throws -> Int {
        let removedCount = events.count
        events.removeAll()
        return removedCount
    }

    func waitUntilBlockedSaveEntered() async {
        guard !hasEnteredBlockedSave else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func releaseBlockedSave() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor RecordingTimingAudioCaptureService: AudioCaptureService {
    struct Snapshot: Sendable, Equatable {
        let isInputRunning: Bool
        let finishCallCount: Int
        let cancelCallCount: Int
    }

    private let audio: CapturedAudio
    private var activeRunID: UUID?
    private var finishCallCount = 0
    private var cancelCallCount = 0
    private var cancellationWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(audio: CapturedAudio) {
        self.audio = audio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        activeRunID = request.runID
    }

    func finishCapture() async throws -> CapturedAudio {
        finishCallCount += 1
        activeRunID = nil
        return audio
    }

    func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
        finishCallCount += 1
        activeRunID = nil
        return .resolved(audio)
    }

    func cancelCapture() async {
        cancelCallCount += 1
        activeRunID = nil
        resumeCancellationWaiters()
    }

    func cancelCapture(runID: UUID) async {
        guard activeRunID == runID else { return }
        cancelCallCount += 1
        activeRunID = nil
        resumeCancellationWaiters()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            isInputRunning: activeRunID != nil,
            finishCallCount: finishCallCount,
            cancelCallCount: cancelCallCount
        )
    }

    func waitUntilCancelled(callCount expectedCount: Int = 1) async {
        guard cancelCallCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((expectedCount, continuation))
        }
    }

    private func resumeCancellationWaiters() {
        let waiters = cancellationWaiters.filter { $0.count <= cancelCallCount }
        cancellationWaiters.removeAll { $0.count <= cancelCallCount }
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}

private actor RecordingTimingCueProbe {
    private let shouldBlock: Bool
    private var callCount = 0
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(shouldBlock: Bool = false) {
        self.shouldBlock = shouldBlock
    }

    func perform() async {
        callCount += 1
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard shouldBlock, !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func calls() -> Int {
        callCount
    }
}

private actor RecordingTimingCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    func snapshot() -> Bool {
        isComplete
    }
}

private actor SequencedRecordingTimingCueProbe {
    private var callCount = 0
    private var releasedCalls: Set<Int> = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func perform() async {
        callCount += 1
        let call = callCount
        let readyWaiters = entryWaiters.filter { $0.count <= call }
        entryWaiters.removeAll { $0.count <= call }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        guard !releasedCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[call] = continuation
        }
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((expectedCount, continuation))
        }
    }

    func release(call: Int) {
        releasedCalls.insert(call)
        releaseWaiters.removeValue(forKey: call)?.resume()
    }
}

final class RecordingSessionManagerTimingTests: XCTestCase {
    func testInvalidatedCueTokenSuppressesLateSynchronousEffect() {
        let token = RecordingCueToken()
        token.invalidate()
        var didPerform = false

        token.performIfValid {
            didPerform = true
        }

        XCTAssertFalse(didPerform)
    }

    func testCancelledRecordingInvalidatesInjectedCueBeforePlatformEffect() async throws {
        let (tokens, continuation) = AsyncStream<RecordingCueToken>.makeStream()
        let manager = makeManager(
            audioCaptureService: try makeAudioCaptureService(testName: #function),
            diagnostics: nil,
            recordingCueAction: { _, token in continuation.yield(token) }
        )
        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        let receivedToken = await tokens.first { _ in true }
        let token = try XCTUnwrap(receivedToken)
        await manager.cancelCurrentRecording()

        var didPerform = false
        token.performIfValid { didPerform = true }

        XCTAssertFalse(didPerform)
        await manager.stopForApplicationShutdown()
        continuation.finish()
    }

    func testFinishingDiagnosticCannotDelayInputShutdown() async throws {
        let repository = BlockingRecordingDiagnosticRepository(
            blockedEvent: "recording.finishing"
        )
        let diagnostics = DiagnosticsRecorder(repository: repository)
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: diagnostics
        )

        await manager.beginPushToTalk()
        let finishTask = Task {
            await manager.endPushToTalk()
        }
        await repository.waitUntilBlockedSaveEntered()

        let capture = await audioCaptureService.snapshot()
        XCTAssertEqual(
            capture.finishCallCount,
            1,
            "The capture service must stop input before diagnostic persistence can suspend."
        )
        XCTAssertFalse(
            capture.isInputRunning,
            "No microphone input may remain active while the finishing diagnostic is blocked."
        )

        await repository.releaseBlockedSave()
        await finishTask.value
        await manager.stopForApplicationShutdown()
    }

    func testBlockedStartedDiagnosticDoesNotDelayStartCueAndShutdownDrainsIt() async throws {
        let repository = BlockingRecordingDiagnosticRepository(
            blockedEvent: "recording.started"
        )
        let diagnostics = DiagnosticsRecorder(repository: repository)
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let cueProbe = RecordingTimingCueProbe()
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: diagnostics,
            cueProbe: cueProbe
        )
        let startTask = Task {
            await manager.beginPushToTalk()
        }
        await repository.waitUntilBlockedSaveEntered()
        await cueProbe.waitUntilEntered()

        let captureWhileDiagnosticIsBlocked = await audioCaptureService.snapshot()
        let cueCallsWhileDiagnosticIsBlocked = await cueProbe.calls()
        XCTAssertTrue(captureWhileDiagnosticIsBlocked.isInputRunning)
        XCTAssertEqual(
            cueCallsWhileDiagnosticIsBlocked,
            1,
            "A durable diagnostic write must not delay feedback after capture is ready."
        )
        await startTask.value

        let shutdownCompletion = RecordingTimingCompletionProbe()
        let shutdownTask = Task {
            await manager.stopForApplicationShutdown()
            await shutdownCompletion.markComplete()
        }
        await audioCaptureService.waitUntilCancelled()
        for _ in 0..<100 {
            await Task.yield()
        }
        let completedBeforeDiagnosticRelease = await shutdownCompletion.snapshot()
        XCTAssertFalse(
            completedBeforeDiagnosticRelease,
            "Shutdown must still drain an accepted diagnostic write."
        )

        await repository.releaseBlockedSave()
        await shutdownTask.value

        let finalCueCalls = await cueProbe.calls()
        XCTAssertEqual(
            finalCueCalls,
            1,
            "The already-delivered start cue must not be duplicated after diagnostic persistence resumes."
        )
    }

    func testBlockedHotkeyDiagnosticDoesNotDelayCaptureStartOrRelease() async throws {
        let repository = BlockingRecordingDiagnosticRepository(
            blockedEvent: "recording.hotkey.pressed"
        )
        let diagnostics = DiagnosticsRecorder(repository: repository)
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let cueProbe = RecordingTimingCueProbe()
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: diagnostics,
            cueProbe: cueProbe
        )

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await repository.waitUntilBlockedSaveEntered()
        await cueProbe.waitUntilEntered()

        var capture = await audioCaptureService.snapshot()
        XCTAssertTrue(capture.isInputRunning)
        guard case .recording = await manager.currentState() else {
            return XCTFail("Capture must become ready while hotkey diagnostics are blocked.")
        }

        await manager.processHotkeyEvent(.pushToTalkReleased(.fnHold))
        capture = await audioCaptureService.snapshot()
        XCTAssertFalse(
            capture.isInputRunning,
            "The release event must stop input without waiting for the earlier press diagnostic."
        )
        XCTAssertEqual(capture.finishCallCount, 1)

        await repository.releaseBlockedSave()
        await manager.stopForApplicationShutdown()
    }

    func testShutdownWaitsForEnteredRecordingCueToComplete() async throws {
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let cueProbe = RecordingTimingCueProbe(shouldBlock: true)
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: nil,
            cueProbe: cueProbe
        )

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await cueProbe.waitUntilEntered()

        let completion = RecordingTimingCompletionProbe()
        let shutdownTask = Task {
            await manager.stopForApplicationShutdown()
            await completion.markComplete()
        }
        await audioCaptureService.waitUntilCancelled()
        for _ in 0..<100 {
            await Task.yield()
        }

        let completedBeforeCueRelease = await completion.snapshot()
        XCTAssertFalse(
            completedBeforeCueRelease,
            "Shutdown must retain and drain a start task that is already performing its cue."
        )

        await cueProbe.release()
        await shutdownTask.value
        let completedAfterCueRelease = await completion.snapshot()
        XCTAssertTrue(completedAfterCueRelease)
    }

    func testOldCueCompletionCannotClearNewRunTaskBeforeShutdownDrain() async throws {
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let cueProbe = SequencedRecordingTimingCueProbe()
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: nil,
            recordingCueAction: { _, _ in
                await cueProbe.perform()
            }
        )

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await cueProbe.waitUntilCallCount(1)
        await manager.cancelCurrentRecording()

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await cueProbe.waitUntilCallCount(2)
        await cueProbe.release(call: 1)
        while await manager.completedStartCueCountForTesting < 1 {
            await Task.yield()
        }

        let completion = RecordingTimingCompletionProbe()
        let shutdownTask = Task {
            await manager.stopForApplicationShutdown()
            await completion.markComplete()
        }
        await audioCaptureService.waitUntilCancelled(callCount: 2)
        for _ in 0..<100 {
            await Task.yield()
        }
        let completedBeforeSecondCueRelease = await completion.snapshot()
        XCTAssertFalse(
            completedBeforeSecondCueRelease,
            "A stale run must not clear the newer pending start task that shutdown must drain."
        )

        await cueProbe.release(call: 2)
        await shutdownTask.value
        let completedAfterSecondCueRelease = await completion.snapshot()
        XCTAssertTrue(completedAfterSecondCueRelease)
    }

    func testShutdownDrainsCancelledOldAndCurrentStartTasks() async throws {
        let audioCaptureService = try makeAudioCaptureService(testName: #function)
        let cueProbe = SequencedRecordingTimingCueProbe()
        let manager = makeManager(
            audioCaptureService: audioCaptureService,
            diagnostics: nil,
            recordingCueAction: { _, _ in
                await cueProbe.perform()
            }
        )

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await cueProbe.waitUntilCallCount(1)
        await manager.cancelCurrentRecording()

        await manager.processHotkeyEvent(.pushToTalkPressed(.fnHold))
        await cueProbe.waitUntilCallCount(2)

        let completion = RecordingTimingCompletionProbe()
        let shutdownTask = Task {
            await manager.stopForApplicationShutdown()
            await completion.markComplete()
        }
        await audioCaptureService.waitUntilCancelled(callCount: 2)

        await cueProbe.release(call: 2)
        for _ in 0..<100 {
            await Task.yield()
        }
        let completedAfterCurrentTaskReleased = await completion.snapshot()
        XCTAssertFalse(
            completedAfterCurrentTaskReleased,
            "Shutdown must retain an older cancelled start task until it actually exits."
        )

        await cueProbe.release(call: 1)
        await shutdownTask.value
        let completedAfterAllTasksReleased = await completion.snapshot()
        XCTAssertTrue(completedAfterAllTasksReleased)
    }
}

private func makeAudioCaptureService(
    testName: String
) throws -> RecordingTimingAudioCaptureService {
    let audio = try CapturedAudio(
        durationSeconds: 1,
        format: AudioFormat(
            sampleRateHz: 16_000,
            channelCount: 1,
            encoding: .pcm16
        ),
        inlineData: Data(testName.utf8)
    )
    return RecordingTimingAudioCaptureService(audio: audio)
}

private func makeManager(
    audioCaptureService: RecordingTimingAudioCaptureService,
    diagnostics: DiagnosticsRecorder?,
    cueProbe: RecordingTimingCueProbe = RecordingTimingCueProbe(),
    recordingCueAction: (@Sendable (RecordingInteractionCue, RecordingCueToken) async -> Void)? = nil
) -> RecordingSessionManager {
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(

        recognizerRegistry: SpeechRecognizerRegistry(
            recognizers: [RecordingTimingRecognizer()]
        ),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: OutputActionRegistry(actions: []),
        candidateResolver: CandidateResolver(eventBus: eventBus),
        eventBus: eventBus,
        diagnostics: diagnostics
    )
    let queue = CapturedAudioProcessingQueue(
        sessionCoordinator: coordinator,
        eventBus: eventBus,
        diagnostics: diagnostics
    )
    let workflow = WorkflowDefinition(
        name: "Recording Timing Workflow",
        trigger: .hotkey,
        pipeline: PipelineDeclaration(
            recognizerID: "recording.timing-recognizer",
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "mic.fill", accentColorName: "red")
    )
    let privacyRunGate = PrivacyRunGate(
        settingsProvider: {
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.localSpeech]) }
    )

    return RecordingSessionManager(
        audioCaptureService: audioCaptureService,
        hotkeyTap: HotkeyEventTap(),
        capturedAudioProcessingQueue: queue,
        eventBus: eventBus,
        diagnostics: diagnostics,
        privacyRunGate: privacyRunGate,
        workflowProvider: { [workflow] },
        recordingCueAction: recordingCueAction ?? { _, _ in
            await cueProbe.perform()
        }
    )
}
