import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private actor AudioLifecycleExecutionProbe {
    private var contextCount = 0
    private var recognitionCount = 0
    private var actionCount = 0

    func recordContext() {
        contextCount += 1
    }

    func recordRecognition() {
        recognitionCount += 1
    }

    func recordAction() {
        actionCount += 1
    }

    func snapshot() -> (context: Int, recognition: Int, action: Int) {
        (contextCount, recognitionCount, actionCount)
    }
}

private struct RejectedCleanupTestError: Error, LocalizedError {
    var errorDescription: String? {
        "cleanup-retry-canary at /Users/alice/private-recording.wav"
    }
}

private actor RejectedCleanupRetryProbe {
    private let failuresBeforeSuccess: Int
    private var attemptCount = 0
    private var retryDelays: [Duration] = []

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func remove(_ capturedAudio: CapturedAudio) throws {
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess {
            throw RejectedCleanupTestError()
        }
        _ = try capturedAudio.removeManagedTemporaryFile()
    }

    func sleep(for delay: Duration) {
        retryDelays.append(delay)
    }

    func snapshot() -> (attempts: Int, delays: [Duration]) {
        (attemptCount, retryDelays)
    }
}

private actor CleanupRetrySleepGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor ProcessingCleanupRetryGate {
    private var attempts = 0
    private var retryEntered = false
    private var retryReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func remove(_ capturedAudio: CapturedAudio) async throws {
        attempts += 1
        if attempts == 1 {
            throw RejectedCleanupTestError()
        }

        retryEntered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !retryReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        _ = try capturedAudio.removeManagedTemporaryFile()
    }

    func waitUntilRetryEntered() async {
        guard !retryEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func releaseRetry() {
        retryReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    var attemptCount: Int { attempts }
}

private actor QueueShutdownCompletionProbe {
    private var isComplete = false

    func markComplete() {
        isComplete = true
    }

    var completed: Bool { isComplete }
}

private actor QueueOwnershipTransferGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendAfterTransfer() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class DeferredCancellationCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private var cancellationCount = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func makeDeferredCapture() -> DeferredCapturedAudio {
        let fileURL = fileURL
        return DeferredCapturedAudio(
            task: Task {
                try await withTaskCancellationHandler {
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                } onCancel: { [weak self] in
                    try? FileManager.default.removeItem(at: fileURL)
                    self?.lock.withLock {
                        self?.cancellationCount += 1
                    }
                }
            }
        )
    }

    var cancellations: Int {
        lock.withLock { cancellationCount }
    }
}

private struct AudioLifecycleContextProvider: ContextProvider {
    let probe: AudioLifecycleExecutionProbe

    func captureContext() async -> ContextSnapshot {
        await probe.recordContext()
        return .empty
    }
}

private struct AudioLifecycleRecognizer: SpeechRecognizer {
    enum TestError: Error {
        case recognitionFailed
    }

    let id = "audio-lifecycle.recognizer"
    let shouldFail: Bool
    let probe: AudioLifecycleExecutionProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.recordRecognition()
        if shouldFail {
            throw TestError.recognitionFailed
        }
        return RecognitionResult(rawText: "recorded", bestText: "recorded")
    }
}

private struct AudioLifecycleAction: OutputAction {
    let id = "audio-lifecycle.action"
    let probe: AudioLifecycleExecutionProbe

    func execute(text: String, context: ActionContext) async throws -> ActionResult {
        await probe.recordAction()
        return .copiedToClipboard
    }
}

private actor AudioRecoveryStoreProbe: FailedAudioRecoveryStore {
    private(set) var preservedBytes: [Data] = []
    private(set) var preserveCallCount = 0
    private var storedReceipts: [FailedAudioRecoveryReceipt] = []

    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt {
        preserveCallCount += 1
        let bytes = try Data(contentsOf: XCTUnwrap(audio.fileURL))
        preservedBytes.append(bytes)
        let receipt = FailedAudioRecoveryReceipt(
            originalRunID: originalRunID,
            workflowID: workflowID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            durationSeconds: audio.durationSeconds,
            format: audio.format,
            plaintextByteCount: bytes.count,
            failureStage: failure.stage,
            failureCode: failure.code
        )
        storedReceipts.append(receipt)
        return receipt
    }

    func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt] {
        storedReceipts
    }

    func materializeForRetry(
        id: UUID,
        attemptID: UUID,
        now: Date
    ) async throws -> CapturedAudio {
        throw FailedAudioRecoveryError.notFound
    }

    func restoreAfterFailedRetry(id: UUID, attemptID: UUID) async throws {}

    func delete(id: UUID) async throws {
        storedReceipts.removeAll { $0.id == id }
    }

    func deleteAll() async throws {
        storedReceipts.removeAll()
    }

    func purgeExpired(now: Date) async throws -> Int { 0 }
}

final class CapturedAudioProcessingQueueLifecycleTests: XCTestCase {
    func testLegacyClipboardWorkflowCleansManagedTemporaryFileWithoutProcessing() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let executionProbe = AudioLifecycleExecutionProbe()
        let recoveryStore = AudioRecoveryStoreProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            recoveryStore: recoveryStore,
            recoveryEnabled: true,
            executionProbe: executionProbe
        )
        var workflow = makeWorkflow()
        workflow.metadata["eventType"] = "groupItemCreated"

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )

        await waitUntilRejectedCleanupFinishes(queue)

        let counts = await executionProbe.snapshot()
        let preservedBytes = await recoveryStore.preservedBytes
        let pendingCount = await queue.pendingCount
        XCTAssertEqual(pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(counts.context, 0)
        XCTAssertEqual(counts.recognition, 0)
        XCTAssertEqual(counts.action, 0)
        XCTAssertTrue(preservedBytes.isEmpty)
    }

    func testLegacyClipboardCleanupRetriesAfterTransientFailureWithoutProcessing() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let executionProbe = AudioLifecycleExecutionProbe()
        let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 1)
        let recoveryStore = AudioRecoveryStoreProbe()
        let diagnostics = DiagnosticsRecorder()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            recoveryStore: recoveryStore,
            recoveryEnabled: true,
            executionProbe: executionProbe,
            diagnostics: diagnostics,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupProbe.remove(capturedAudio)
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(1),
            rejectedCleanupMaximumRetryDelay: .milliseconds(4),
            rejectedCleanupSleep: { delay in
                await cleanupProbe.sleep(for: delay)
            }
        )
        var workflow = makeWorkflow()
        workflow.metadata["eventType"] = "groupItemCreated"

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )
        await waitUntilRejectedCleanupFinishes(queue)

        let cleanup = await cleanupProbe.snapshot()
        let execution = await executionProbe.snapshot()
        let preserveCallCount = await recoveryStore.preserveCallCount
        let pendingCount = await queue.pendingCount
        let rejectedCleanupCount = await queue.rejectedCleanupCount
        let diagnosticEvents = await diagnostics.snapshot()
        let cleanupFailure = try XCTUnwrap(
            diagnosticEvents.first {
                $0.event == "audio-processing.rejected-cleanup-pending"
            }
        )
        XCTAssertEqual(cleanup.attempts, 2)
        XCTAssertEqual(cleanup.delays, [.milliseconds(1)])
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(rejectedCleanupCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)
        XCTAssertEqual(preserveCallCount, 0)
        XCTAssertEqual(cleanupFailure.message, DiagnosticEventSanitizer.sanitizedMessage)
        XCTAssertEqual(cleanupFailure.metadata, ["lane": "interactive"])
        XCTAssertFalse(cleanupFailure.message.lowercased().contains("canary"))
    }

    func testLegacyClipboardCleanupRetryDelayStopsGrowingAtMaximum() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let executionProbe = AudioLifecycleExecutionProbe()
        let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 4)
        let queue = await makeQueue(
            recognitionShouldFail: false,
            executionProbe: executionProbe,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupProbe.remove(capturedAudio)
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(1),
            rejectedCleanupMaximumRetryDelay: .milliseconds(2),
            rejectedCleanupSleep: { delay in
                await cleanupProbe.sleep(for: delay)
            }
        )
        var workflow = makeWorkflow()
        workflow.metadata["eventType"] = "groupItemCreated"

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: workflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )
        await waitUntilRejectedCleanupFinishes(queue)

        let cleanup = await cleanupProbe.snapshot()
        let execution = await executionProbe.snapshot()
        XCTAssertEqual(cleanup.attempts, 5)
        XCTAssertEqual(
            cleanup.delays,
            [.milliseconds(1), .milliseconds(2), .milliseconds(2), .milliseconds(2)]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)
    }

    func testRejectedCaptureResolutionFailureIsTerminalWithoutRetryOrProcessing() async throws {
        let executionProbe = AudioLifecycleExecutionProbe()
        let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 0)
        let recoveryStore = AudioRecoveryStoreProbe()
        let diagnostics = DiagnosticsRecorder()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            recoveryStore: recoveryStore,
            recoveryEnabled: true,
            executionProbe: executionProbe,
            diagnostics: diagnostics,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupProbe.remove(capturedAudio)
            },
            rejectedCleanupInitialRetryDelay: .milliseconds(1),
            rejectedCleanupMaximumRetryDelay: .milliseconds(2),
            rejectedCleanupSleep: { delay in
                await cleanupProbe.sleep(for: delay)
            }
        )
        let workflow = makeWorkflow()
        let failedCapture = DeferredCapturedAudio(
            task: Task<CapturedAudio, Error> {
                throw RejectedCleanupTestError()
            }
        )

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: workflow
            ),
            triggerEvent: WorkflowTriggerEvent(
                binding: .manual,
                workflowID: UUID(),
                sourceID: "rejected-capture-resolution-test"
            ),
            deferredCapture: failedCapture
        )
        await waitUntilDrained(queue)
        await waitUntilRejectedCleanupFinishes(queue)
        try? await Task.sleep(for: .milliseconds(10))

        let cleanup = await cleanupProbe.snapshot()
        let execution = await executionProbe.snapshot()
        let preserveCallCount = await recoveryStore.preserveCallCount
        let rejectedCleanupCount = await queue.rejectedCleanupCount
        let diagnosticEvents = await diagnostics.snapshot()
        let resolutionFailures = diagnosticEvents.filter {
            $0.event == "audio-processing.rejected-capture-resolution-failed"
        }
        XCTAssertEqual(cleanup.attempts, 0)
        XCTAssertTrue(cleanup.delays.isEmpty)
        XCTAssertEqual(rejectedCleanupCount, 0)
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)
        XCTAssertEqual(preserveCallCount, 0)
        XCTAssertEqual(resolutionFailures.count, 1)
        XCTAssertEqual(
            resolutionFailures.first?.message,
            DiagnosticEventSanitizer.sanitizedMessage
        )
        XCTAssertEqual(
            resolutionFailures.first?.metadata,
            ["lane": "interactive"]
        )
        XCTAssertFalse(
            diagnosticEvents.contains {
                $0.event == "audio-processing.rejected-cleanup-pending"
            }
        )
        XCTAssertFalse(
            resolutionFailures.first?.message.lowercased().contains("canary") == true
        )
    }

    func testQueueRemovesManagedTemporaryFileAfterProcessingOutcome() async throws {
        for recognitionShouldFail in [false, true] {
            let fileURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let queue = await makeQueue(recognitionShouldFail: recognitionShouldFail)

            await queue.enqueue(
                authorizationLease: makeAudioProcessingTestLease(
                    runID: UUID(),
                    workflow: makeWorkflow()
                ),
                triggerEvent: nil,
                deferredCapture: .resolved(
                    try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
                )
            )

            await waitUntilDrained(queue)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fileURL.path),
                "Managed audio remained after recognitionShouldFail=\(recognitionShouldFail)."
            )
        }
    }

    func testProcessingOutcomesRetryTransientManagedFileRemovalFailure() async throws {
        for recognitionShouldFail in [false, true] {
            let fileURL = try makeAudioFile()
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 1)
            let queue = await makeQueue(
                recognitionShouldFail: recognitionShouldFail,
                rejectedCapturedAudioRemoval: { capturedAudio in
                    try await cleanupProbe.remove(capturedAudio)
                },
                rejectedCleanupSleep: { delay in
                    await cleanupProbe.sleep(for: delay)
                }
            )

            await queue.enqueue(
                authorizationLease: makeAudioProcessingTestLease(
                    runID: UUID(),
                    workflow: makeWorkflow()
                ),
                triggerEvent: nil,
                deferredCapture: .resolved(
                    try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
                )
            )

            await waitUntilDrained(queue)
            await waitUntilRejectedCleanupFinishes(queue)
            let cleanup = await cleanupProbe.snapshot()
            XCTAssertEqual(cleanup.attempts, 2)
            XCTAssertTrue(cleanup.delays.isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fileURL.path),
                "Managed audio remained after recognitionShouldFail=\(recognitionShouldFail)."
            )
        }
    }

    func testShutdownWaitsForManagedFileRemovalRetry() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let cleanupGate = ProcessingCleanupRetryGate()
        let completionProbe = QueueShutdownCompletionProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupGate.remove(capturedAudio)
            }
        )

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: makeWorkflow()
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )
        await cleanupGate.waitUntilRetryEntered()

        let shutdownTask = Task {
            await queue.shutdown()
            await completionProbe.markComplete()
        }
        await Task.yield()
        let completedBeforeRelease = await completionProbe.completed
        XCTAssertFalse(completedBeforeRelease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        await cleanupGate.releaseRetry()
        await shutdownTask.value

        let completedAfterRelease = await completionProbe.completed
        let attemptCount = await cleanupGate.attemptCount
        XCTAssertTrue(completedAfterRelease)
        XCTAssertEqual(attemptCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testOptInQueueProtectsFailedManagedAudioBeforeRemovingPlaintext() async throws {
        let fileURL = try makeAudioFile(bytes: Data([0x11, 0x22, 0x33]))
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recoveryStore = AudioRecoveryStoreProbe()
        let queue = await makeQueue(
            recognitionShouldFail: true,
            recoveryStore: recoveryStore,
            recoveryEnabled: true
        )
        let workflow = makeWorkflow()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(runID: UUID(), workflow: workflow),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )

        await waitUntilDrained(queue)
        let preservedBytes = await recoveryStore.preservedBytes
        XCTAssertEqual(preservedBytes, [Data([0x11, 0x22, 0x33])])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testQueueDoesNotRetainFailedAudioWithoutExplicitOptIn() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recoveryStore = AudioRecoveryStoreProbe()
        let queue = await makeQueue(
            recognitionShouldFail: true,
            recoveryStore: recoveryStore,
            recoveryEnabled: false
        )
        let workflow = makeWorkflow()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(runID: UUID(), workflow: workflow),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )

        await waitUntilDrained(queue)
        let preservedBytes = await recoveryStore.preservedBytes
        XCTAssertTrue(preservedBytes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testQueueNeverRemovesCallerManagedFile() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let queue = await makeQueue(recognitionShouldFail: false)
        let workflow = makeWorkflow()

        await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(runID: UUID(), workflow: workflow),
            triggerEvent: nil,
            deferredCapture: .resolved(try makeCapturedAudio(fileURL: fileURL, ownership: .callerManaged))
        )

        await waitUntilDrained(queue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testTerminatedQueueRejectsEnqueueAndLeavesCleanupWithCaller() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let executionProbe = AudioLifecycleExecutionProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            executionProbe: executionProbe
        )
        await queue.shutdown()
        let deferredCapture = DeferredCapturedAudio.resolved(
            try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
        )

        let transfer = await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: makeWorkflow()
            ),
            triggerEvent: nil,
            deferredCapture: deferredCapture
        )

        XCTAssertEqual(transfer, .rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let execution = await executionProbe.snapshot()
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)

        _ = try await deferredCapture.discardManagedTemporaryFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRunCancellationDuringAcceptedTransferWindowCleansExactlyOnce() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let runID = UUID()
        let transferGate = QueueOwnershipTransferGate()
        let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 0)
        let executionProbe = AudioLifecycleExecutionProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            executionProbe: executionProbe,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupProbe.remove(capturedAudio)
            },
            ownershipTransferObserver: { _ in
                await transferGate.suspendAfterTransfer()
            }
        )
        let deferredCapture = DeferredCapturedAudio.resolved(
            try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
        )
        let authorizationLease = makeAudioProcessingTestLease(
            runID: runID,
            workflow: makeWorkflow()
        )
        let enqueueTask = Task {
            await queue.enqueue(
                authorizationLease: authorizationLease,
                triggerEvent: nil,
                deferredCapture: deferredCapture
            )
        }
        await transferGate.waitUntilEntered()

        await queue.cancel(runID: runID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingCount = await queue.pendingCount
        let cleanup = await cleanupProbe.snapshot()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(cleanup.attempts, 1)
        let execution = await executionProbe.snapshot()
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)

        await transferGate.release()
        let transfer = await enqueueTask.value
        XCTAssertEqual(transfer, .accepted)
        await queue.shutdown()
    }

    func testShutdownDuringAcceptedTransferWindowSettlesAllWaitersAndCleanup() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let runID = UUID()
        let transferGate = QueueOwnershipTransferGate()
        let executionProbe = AudioLifecycleExecutionProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            executionProbe: executionProbe,
            ownershipTransferObserver: { _ in
                await transferGate.suspendAfterTransfer()
            }
        )
        let deferredCapture = DeferredCapturedAudio.resolved(
            try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
        )
        let authorizationLease = makeAudioProcessingTestLease(
            runID: runID,
            workflow: makeWorkflow()
        )
        let enqueueTask = Task {
            await queue.enqueue(
                authorizationLease: authorizationLease,
                triggerEvent: nil,
                deferredCapture: deferredCapture
            )
        }
        await transferGate.waitUntilEntered()

        async let firstShutdown: Void = queue.shutdown()
        async let secondShutdown: Void = queue.shutdown()
        _ = await (firstShutdown, secondShutdown)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingCount = await queue.pendingCount
        let cleanupCount = await queue.rejectedCleanupCount
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(cleanupCount, 0)
        await transferGate.release()
        let transfer = await enqueueTask.value
        XCTAssertEqual(transfer, .accepted)
        let execution = await executionProbe.snapshot()
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)
    }

    func testShutdownCancelsUnderlyingActiveDeferredTaskAndReturns() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let runID = UUID()
        let cancellationProbe = DeferredCancellationCleanupProbe(fileURL: fileURL)
        let executionProbe = AudioLifecycleExecutionProbe()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            executionProbe: executionProbe
        )
        let transfer = await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: runID,
                workflow: makeWorkflow()
            ),
            triggerEvent: nil,
            deferredCapture: cancellationProbe.makeDeferredCapture()
        )
        XCTAssertEqual(transfer, .accepted)
        await waitUntilActive(runID: runID, queue: queue)

        await queue.shutdown()

        XCTAssertEqual(cancellationProbe.cancellations, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let pendingCount = await queue.pendingCount
        XCTAssertEqual(pendingCount, 0)
        let execution = await executionProbe.snapshot()
        XCTAssertEqual(execution.context, 0)
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(execution.action, 0)
    }

    func testCancellingFirstShutdownStillTerminatesQueueAndResumesConcurrentWaiter() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let cleanupProbe = RejectedCleanupRetryProbe(failuresBeforeSuccess: 1)
        let sleepGate = CleanupRetrySleepGate()
        let queue = await makeQueue(
            recognitionShouldFail: false,
            rejectedCapturedAudioRemoval: { capturedAudio in
                try await cleanupProbe.remove(capturedAudio)
            },
            rejectedCleanupSleep: { _ in
                await sleepGate.sleep()
            }
        )
        var unsupportedWorkflow = makeWorkflow()
        unsupportedWorkflow.metadata["eventType"] = "groupItemCreated"
        let transfer = await queue.enqueue(
            authorizationLease: makeAudioProcessingTestLease(
                runID: UUID(),
                workflow: unsupportedWorkflow
            ),
            triggerEvent: nil,
            deferredCapture: .resolved(
                try makeCapturedAudio(fileURL: fileURL, ownership: .managedTemporary)
            )
        )
        XCTAssertEqual(transfer, .accepted)
        await sleepGate.waitUntilEntered()

        let firstShutdown = Task { await queue.shutdown() }
        await waitUntilShutdownBegins(queue)
        let concurrentShutdown = Task { await queue.shutdown() }
        await Task.yield()
        firstShutdown.cancel()
        await sleepGate.release()
        await firstShutdown.value
        await concurrentShutdown.value

        let cleanupCount = await queue.rejectedCleanupCount
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let cleanup = await cleanupProbe.snapshot()
        XCTAssertEqual(cleanup.attempts, 2)
        await queue.shutdown()
    }

    private func makeQueue(
        recognitionShouldFail: Bool,
        recoveryStore: (any FailedAudioRecoveryStore)? = nil,
        recoveryEnabled: Bool = false,
        executionProbe providedExecutionProbe: AudioLifecycleExecutionProbe? = nil,
        diagnostics providedDiagnostics: DiagnosticsRecorder? = nil,
        rejectedCapturedAudioRemoval: (
            @Sendable (CapturedAudio) async throws -> Void
        )? = nil,
        rejectedCleanupInitialRetryDelay: Duration = .milliseconds(1),
        rejectedCleanupMaximumRetryDelay: Duration = .milliseconds(4),
        rejectedCleanupSleep: (@Sendable (Duration) async throws -> Void)? = nil,
        ownershipTransferObserver: (@Sendable (UUID) async -> Void)? = nil
    ) async -> CapturedAudioProcessingQueue {
        let executionProbe = providedExecutionProbe ?? AudioLifecycleExecutionProbe()
        let eventBus = EventBus()
        let diagnostics = providedDiagnostics ?? DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = SessionCoordinator(
            contextProvider: AudioLifecycleContextProvider(probe: executionProbe),
            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    AudioLifecycleRecognizer(
                        shouldFail: recognitionShouldFail,
                        probe: executionProbe
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [AudioLifecycleAction(probe: executionProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let recoveryController = recoveryStore.map { store in
            FailedAudioRecoveryController(
                store: store,
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics
            )
        }
        if let recoveryController {
            try? await recoveryController.refresh(isEnabled: recoveryEnabled)
        }
        if rejectedCapturedAudioRemoval != nil || ownershipTransferObserver != nil {
            let sleep = rejectedCleanupSleep ?? { delay in
                try await Task.sleep(for: delay)
            }
            return CapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus,
                diagnostics: diagnostics,
                failedAudioRecoveryController: recoveryController,
                rejectedCapturedAudioRemoval: rejectedCapturedAudioRemoval ?? { capturedAudio in
                    _ = try capturedAudio.removeManagedTemporaryFile()
                },
                rejectedCleanupInitialRetryDelay: rejectedCleanupInitialRetryDelay,
                rejectedCleanupMaximumRetryDelay: rejectedCleanupMaximumRetryDelay,
                rejectedCleanupSleep: sleep,
                ownershipTransferObserver: ownershipTransferObserver ?? { _ in }
            )
        }
        return CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            failedAudioRecoveryController: recoveryController
        )
    }

    private func makeWorkflow() -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Audio Lifecycle Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "audio-lifecycle.recognizer",
                outputActions: [OutputActionReference(id: "audio-lifecycle.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func makeAudioFile(bytes: Data = Data([0x00])) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-queue-lifecycle-" + UUID().uuidString + ".wav")
        try bytes.write(to: fileURL)
        return fileURL
    }

    private func makeCapturedAudio(
        fileURL: URL,
        ownership: CapturedAudioFileOwnership
    ) throws -> CapturedAudio {
        try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: ownership
        )
    }

    private func waitUntilDrained(_ queue: CapturedAudioProcessingQueue) async {
        for _ in 0..<200 {
            if await queue.pendingCount == 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The captured audio processing queue did not drain.")
    }

    private func waitUntilRejectedCleanupFinishes(
        _ queue: CapturedAudioProcessingQueue
    ) async {
        for _ in 0..<200 {
            if await queue.rejectedCleanupCount == 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The rejected captured audio cleanup did not finish.")
    }

    private func waitUntilActive(
        runID: UUID,
        queue: CapturedAudioProcessingQueue
    ) async {
        for _ in 0..<200 {
            if await queue.activeRunIDForTesting == runID {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The captured audio processing queue did not activate the run.")
    }

    private func waitUntilShutdownBegins(_ queue: CapturedAudioProcessingQueue) async {
        for _ in 0..<200 {
            if await queue.isShutdownInProgressForTesting {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The captured audio processing queue did not begin shutdown.")
    }
}
