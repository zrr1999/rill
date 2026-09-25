import RillPlatform
import RillDomainTestSupport
import Foundation
import XCTest
@testable import RillCore
@testable import RillRuntime

private struct RecoveryControllerContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private enum RecoveryControllerTestError: Error {
    case failed
}

private struct RecoveryControllerRecognizer: SpeechRecognizer {
    let id = "context.selection"
    let shouldFail: Bool
    let shouldCancel: Bool

    init(shouldFail: Bool, shouldCancel: Bool = false) {
        self.shouldFail = shouldFail
        self.shouldCancel = shouldCancel
    }

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        if shouldCancel { throw CancellationError() }
        if shouldFail { throw RecoveryControllerTestError.failed }
        return RecognitionResult(rawText: "recovered", bestText: "recovered")
    }
}

private actor RecoveryExecutionBoundaryProbe {
    private var preflightCount = 0
    private var contextCount = 0
    private var privacySettingsCount = 0
    private var confirmationCount = 0
    private var optionsCount = 0
    private var recognitionCount = 0

    func recordPreflight() {
        preflightCount += 1
    }

    func readContext() -> ContextSnapshot {
        contextCount += 1
        return .empty
    }

    func readPrivacySettings() -> PrivacyPolicySettings {
        privacySettingsCount += 1
        return .defaults
    }

    func confirmCloudRun() -> Bool {
        confirmationCount += 1
        return true
    }

    func resolveOptions() -> SpeechRecognitionRequestOptions {
        optionsCount += 1
        return .empty
    }

    func recordRecognition() {
        recognitionCount += 1
    }

    func snapshot() -> (
        preflight: Int,
        context: Int,
        privacySettings: Int,
        confirmation: Int,
        options: Int,
        recognition: Int
    ) {
        (
            preflightCount,
            contextCount,
            privacySettingsCount,
            confirmationCount,
            optionsCount,
            recognitionCount
        )
    }
}

private struct RecoveryExecutionBoundaryContextProvider: ContextProvider {
    let probe: RecoveryExecutionBoundaryProbe

    func captureContext() async -> ContextSnapshot {
        await probe.readContext()
    }
}

private struct RecoveryExecutionBoundaryRecognizer: SpeechRecognizer {
    let id = "remote.recovery-boundary"
    let probe: RecoveryExecutionBoundaryProbe

    func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
        await probe.recordRecognition()
        return RecognitionResult(rawText: "unused", bestText: "unused")
    }
}

private actor RecoveryOutputProbe {
    private(set) var executionCount = 0

    func record() {
        executionCount += 1
    }
}

private struct RecoveryProbeAction: OutputAction {
    let id = "recovery-controller.action"
    let probe: RecoveryOutputProbe

    func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
        _ = try record.requireText(for: id)
        await probe.record()
        return .copiedToClipboard
    }
}

private enum RecoveryBarrierError: Error { case notEntered }

private actor RecoveryMaterializationBarrier {
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard entered else { throw RecoveryBarrierError.notEntered }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RecoveryMutablePrivacySettings {
    private var settings: PrivacyPolicySettings

    init(_ settings: PrivacyPolicySettings) {
        self.settings = settings
    }

    func read() -> PrivacyPolicySettings { settings }

    func replace(with settings: PrivacyPolicySettings) {
        self.settings = settings
    }
}

private actor RecoveryControllerStoreProbe: FailedAudioRecoveryStore {
    struct Snapshot: Sendable {
        let receipts: [FailedAudioRecoveryReceipt]
        let materializeCount: Int
        let deleteCount: Int
        let deleteAllCount: Int
        let preserveCount: Int
        let purgeCount: Int
        let receiptsCount: Int
        let lastMaterializedURL: URL?
    }

    private(set) var storedReceipts: [FailedAudioRecoveryReceipt]
    private(set) var materializeCount = 0
    private(set) var deleteCount = 0
    private(set) var deleteAllCount = 0
    private(set) var preserveCount = 0
    private(set) var purgeCount = 0
    private(set) var receiptsCount = 0
    private(set) var lastMaterializedURL: URL?
    private let audioBytes: Data
    private let deleteShouldFail: Bool
    private let deleteAllShouldFail: Bool
    private let restoreShouldFail: Bool
    private let materializationBarrier: RecoveryMaterializationBarrier?
    private let purgeBarrier: RecoveryMaterializationBarrier?
    private var purgeFailuresRemaining: Int

    init(
        receipt: FailedAudioRecoveryReceipt,
        additionalReceipts: [FailedAudioRecoveryReceipt] = [],
        audioBytes: Data = Data([1, 2, 3]),
        deleteShouldFail: Bool = false,
        deleteAllShouldFail: Bool = false,
        restoreShouldFail: Bool = false,
        materializationBarrier: RecoveryMaterializationBarrier? = nil,
        purgeBarrier: RecoveryMaterializationBarrier? = nil,
        purgeFailureCount: Int = 0
    ) {
        storedReceipts = [receipt] + additionalReceipts
        self.audioBytes = audioBytes
        self.deleteShouldFail = deleteShouldFail
        self.deleteAllShouldFail = deleteAllShouldFail
        self.restoreShouldFail = restoreShouldFail
        self.materializationBarrier = materializationBarrier
        self.purgeBarrier = purgeBarrier
        purgeFailuresRemaining = purgeFailureCount
    }

    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt {
        preserveCount += 1
        let receipt = FailedAudioRecoveryReceipt(
            originalRunID: originalRunID,
            workflowID: workflowID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            durationSeconds: audio.durationSeconds,
            format: audio.format,
            plaintextByteCount: audioBytes.count,
            failureStage: failure.stage,
            failureCode: failure.code
        )
        storedReceipts.append(receipt)
        return receipt
    }

    func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt] {
        receiptsCount += 1
        storedReceipts.removeAll { $0.isExpired(at: now) }
        return storedReceipts
    }

    func materializeForRetry(
        id: UUID,
        attemptID: UUID,
        now: Date
    ) async throws -> CapturedAudio {
        guard let index = storedReceipts.firstIndex(where: { $0.id == id }) else {
            throw FailedAudioRecoveryError.notFound
        }
        guard storedReceipts[index].status.canRetry else {
            throw FailedAudioRecoveryError.retryOutcomeUnknown
        }
        guard !storedReceipts[index].isExpired(at: now) else {
            storedReceipts.remove(at: index)
            throw FailedAudioRecoveryError.expired
        }
        storedReceipts[index].status = .retrying(attemptID: attemptID, startedAt: now)
        materializeCount += 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-recovery-controller-\(UUID().uuidString).wav")
        try audioBytes.write(to: url)
        lastMaterializedURL = url
        let capturedAudio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: url,
            fileOwnership: .managedTemporary
        )
        if let materializationBarrier {
            await materializationBarrier.hold()
        }
        return capturedAudio
    }

    func restoreAfterFailedRetry(id: UUID, attemptID: UUID) async throws {
        if restoreShouldFail {
            throw FailedAudioRecoveryError.storageUnavailable
        }
        guard let index = storedReceipts.firstIndex(where: { $0.id == id }),
              case .retrying(let storedAttemptID, _) = storedReceipts[index].status,
              storedAttemptID == attemptID else {
            throw FailedAudioRecoveryError.retryOutcomeUnknown
        }
        storedReceipts[index].status = .available
    }

    func delete(id: UUID) async throws {
        deleteCount += 1
        if deleteShouldFail {
            throw FailedAudioRecoveryError.storageUnavailable
        }
        storedReceipts.removeAll { $0.id == id }
    }

    func deleteAll() async throws {
        deleteAllCount += 1
        if deleteAllShouldFail {
            throw FailedAudioRecoveryError.storageUnavailable
        }
        storedReceipts.removeAll()
    }

    func purgeExpired(now: Date) async throws -> Int {
        purgeCount += 1
        if let purgeBarrier {
            await purgeBarrier.hold()
        }
        if purgeFailuresRemaining > 0 {
            purgeFailuresRemaining -= 1
            throw FailedAudioRecoveryError.storageUnavailable
        }
        let priorCount = storedReceipts.count
        storedReceipts.removeAll { $0.isExpired(at: now) }
        return priorCount - storedReceipts.count
    }

    func snapshot() -> Snapshot {
        Snapshot(
            receipts: storedReceipts,
            materializeCount: materializeCount,
            deleteCount: deleteCount,
            deleteAllCount: deleteAllCount,
            preserveCount: preserveCount,
            purgeCount: purgeCount,
            receiptsCount: receiptsCount,
            lastMaterializedURL: lastMaterializedURL
        )
    }
}

private actor RecoveryTemporaryCleanupProbe {
    private var failuresRemaining: Int
    private var successBarrier: RecoveryMaterializationBarrier?
    private(set) var attemptCount = 0

    init(failureCount: Int, successBarrier: RecoveryMaterializationBarrier? = nil) {
        failuresRemaining = failureCount
        self.successBarrier = successBarrier
    }

    func cleanup() async -> Bool {
        attemptCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return false
        }
        if let barrier = successBarrier {
            successBarrier = nil
            await barrier.hold()
        }
        return true
    }
}

private actor RecoveryShutdownCleanupProbe {
    private var callCount = 0
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    func cleanup() async -> Bool {
        callCount += 1
        let call = callCount
        let readyWaiters = callWaiters.filter { $0.0 <= call }
        callWaiters.removeAll { $0.0 <= call }
        for (_, waiter) in readyWaiters { waiter.resume() }

        // The startup reconciliation is healthy. Later calls are controlled
        // by the test so it can prove shutdown remains pending on failure.
        if call == 1 { return true }
        return await withCheckedContinuation { continuation in
            resultWaiters[call] = continuation
        }
    }

    func waitForCall(_ expectedCallCount: Int) async {
        guard callCount < expectedCallCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCallCount, continuation))
        }
    }

    func resolve(call: Int, result: Bool) {
        resultWaiters.removeValue(forKey: call)?.resume(returning: result)
    }
}

private actor RecoveryShutdownCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor RecoveryPreflightProbe {
    private(set) var callCount = 0

    func record() {
        callCount += 1
    }
}

private actor BlockingRecoveryPreflightProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor BlockingPreserveRecoveryStore: FailedAudioRecoveryStore {
    struct Snapshot: Sendable {
        let receipts: [FailedAudioRecoveryReceipt]
        let deleteAllCount: Int
    }

    private var storedReceipts: [FailedAudioRecoveryReceipt] = []
    private var preserveStarted = false
    private var deleteAllCount = 0
    private var preserveRelease: CheckedContinuation<Void, Never>?
    private var preserveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var deleteAllWaiters: [CheckedContinuation<Void, Never>] = []

    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt {
        preserveStarted = true
        let startWaiters = preserveStartWaiters
        preserveStartWaiters.removeAll()
        for waiter in startWaiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            preserveRelease = continuation
        }
        let receipt = FailedAudioRecoveryReceipt(
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
        deleteAllCount += 1
        storedReceipts.removeAll()
        let waiters = deleteAllWaiters
        deleteAllWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func purgeExpired(now: Date) async throws -> Int { 0 }

    func waitUntilPreserveStarts() async {
        guard !preserveStarted else { return }
        await withCheckedContinuation { continuation in
            preserveStartWaiters.append(continuation)
        }
    }

    func waitUntilDeleteAllStarts() async {
        guard deleteAllCount == 0 else { return }
        await withCheckedContinuation { continuation in
            deleteAllWaiters.append(continuation)
        }
    }

    func releasePreserve() {
        preserveRelease?.resume()
        preserveRelease = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(receipts: storedReceipts, deleteAllCount: deleteAllCount)
    }
}

private actor BlockingRefreshRecoveryStore: FailedAudioRecoveryStore {
    struct Snapshot: Sendable {
        let preserveCount: Int
        let deleteAllCount: Int
    }

    private var storedReceipts: [FailedAudioRecoveryReceipt]
    private var shouldBlockReceipts = true
    private var receiptsStarted = false
    private var receiptsRelease: CheckedContinuation<Void, Never>?
    private var receiptsStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var preserveCount = 0
    private var deleteAllCount = 0

    init(receipt: FailedAudioRecoveryReceipt) {
        storedReceipts = [receipt]
    }

    func preserve(
        audio: CapturedAudio,
        originalRunID: UUID,
        workflowID: UUID,
        failure: WorkflowRunFailureSummary,
        now: Date
    ) async throws -> FailedAudioRecoveryReceipt {
        preserveCount += 1
        let receipt = FailedAudioRecoveryReceipt(
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
        storedReceipts.append(receipt)
        return receipt
    }

    func receipts(now: Date) async throws -> [FailedAudioRecoveryReceipt] {
        if shouldBlockReceipts {
            shouldBlockReceipts = false
            receiptsStarted = true
            let waiters = receiptsStartWaiters
            receiptsStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                receiptsRelease = continuation
            }
        }
        return storedReceipts
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
        deleteAllCount += 1
        storedReceipts.removeAll()
    }

    func purgeExpired(now: Date) async throws -> Int { 0 }

    func waitUntilReceiptsStarts() async {
        guard !receiptsStarted else { return }
        await withCheckedContinuation { continuation in
            receiptsStartWaiters.append(continuation)
        }
    }

    func releaseReceipts() {
        receiptsRelease?.resume()
        receiptsRelease = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(preserveCount: preserveCount, deleteAllCount: deleteAllCount)
    }
}

private final class LockedRecoveryDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

final class FailedAudioRecoveryControllerTests: XCTestCase {
    func testApplicationShutdownRejectsEveryLatePublicOperation() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let cleanupProbe = RecoveryTemporaryCleanupProbe(failureCount: 0)
        let preflightProbe = RecoveryPreflightProbe()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            runPreflight: { _ in await preflightProbe.record() },
            cleanupRecoveryTemporaryFiles: { await cleanupProbe.cleanup() }
        )

        await controller.stopForApplicationShutdown()
        try await controller.refresh(isEnabled: true)
        try await controller.refresh(isEnabled: false)

        do {
            _ = try await controller.currentReceipts()
            XCTFail("Shutdown must reject a late receipt refresh.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }
        do {
            try await controller.delete(id: receipt.id)
            XCTFail("Shutdown must reject a late delete.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }
        do {
            try await controller.deleteAll()
            XCTFail("Shutdown must reject a late clear.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }
        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Shutdown must reject a late retry.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }

        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            inlineData: Data([1])
        )
        let preserved = try await controller.preserveIfEnabled(
            audio: audio,
            originalRunID: UUID(),
            workflowID: workflow.id,
            failure: WorkflowRunFailureSummary(
                runID: UUID(),
                stage: .recognizing,
                code: .processing
            )
        )

        XCTAssertNil(preserved)
        let snapshot = await store.snapshot()
        let cleanupAttemptCount = await cleanupProbe.attemptCount
        let preflightCallCount = await preflightProbe.callCount
        XCTAssertEqual(snapshot.preserveCount, 0)
        XCTAssertEqual(snapshot.receiptsCount, 0)
        XCTAssertEqual(snapshot.deleteCount, 0)
        XCTAssertEqual(snapshot.deleteAllCount, 0)
        XCTAssertEqual(snapshot.materializeCount, 0)
        XCTAssertEqual(snapshot.receipts, [receipt])
        XCTAssertEqual(cleanupAttemptCount, 1)
        XCTAssertEqual(preflightCallCount, 0)
    }

    func testMissingPrivacyGateFailsBeforeRecoveryAudioMaterialization() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            privacyRunGate: nil
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("A missing privacy gate must block recovery.")
        } catch let error as SessionCoordinator.SessionError {
            guard case .privacyAuthorizationRequired = error else {
                return XCTFail("Unexpected session error: \(error)")
            }
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.materializeCount, 0)
        XCTAssertEqual(snapshot.receipts, [receipt])
    }

    func testLegacyClipboardWorkflowRetryIsRejectedBeforeGatesDecryptionOrExecution() async throws {
        let probe = RecoveryExecutionBoundaryProbe()
        let outputProbe = RecoveryOutputProbe()
        let workflow = WorkflowDefinition(
            name: "Legacy Clipboard Automation",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "remote.recovery-boundary",
                outputActions: [OutputActionReference(id: "recovery-controller.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
            metadata: ["eventType": "groupItemCreated"]
        )
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [RecoveryExecutionBoundaryRecognizer(probe: probe)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [RecoveryProbeAction(probe: outputProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let privacyGate = PrivacyRunGate(
            settingsProvider: { await probe.readPrivacySettings() },
            cloudConfirmationProvider: { _, _, _ in await probe.confirmCloudRun() }
        )
        let controller = makeTestFailedAudioRecoveryController(
            store: store,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: privacyGate,

            privacyContextProvider: { await probe.readContext() },
            authorizedContextProvider: { _ in await probe.readContext() },
            recognitionOptionsProvider: { _, _ in await probe.resolveOptions() },
            runPreflight: { _ in await probe.recordPreflight() },
            currentDate: { Date(timeIntervalSince1970: 101) }
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected legacy clipboard automation to be rejected.")
        } catch let error as SessionCoordinator.SessionError {
            guard case .unsupportedWorkflow(.legacyClipboardAutomationUnsupported) = error else {
                return XCTFail("Unexpected session error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let counts = await probe.snapshot()
        let storeSnapshot = await store.snapshot()
        let outputExecutionCount = await outputProbe.executionCount
        XCTAssertEqual(counts.preflight, 0)
        XCTAssertEqual(counts.context, 0)
        XCTAssertEqual(counts.privacySettings, 0)
        XCTAssertEqual(counts.confirmation, 0)
        XCTAssertEqual(counts.options, 0)
        XCTAssertEqual(storeSnapshot.materializeCount, 0)
        XCTAssertEqual(counts.recognition, 0)
        XCTAssertEqual(outputExecutionCount, 0)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
    }

    func testDisabledControllerRejectsRetryBeforePreflightOrDecryption() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let preflightProbe = RecoveryPreflightProbe()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            runPreflight: { _ in await preflightProbe.record() }
        )

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected disabled recovery to reject retry.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }

        let preflightCallCount = await preflightProbe.callCount
        XCTAssertEqual(preflightCallCount, 0)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.materializeCount, 0)
    }

    func testManualRetryUsesCurrentPipelineButNeverRepeatsOutputActions() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let outputProbe = RecoveryOutputProbe()
        let preflightProbe = RecoveryPreflightProbe()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            outputProbe: outputProbe,
            runPreflight: { _ in await preflightProbe.record() }
        )
        try await controller.refresh(isEnabled: true)

        let result = try await controller.retry(id: receipt.id, workflow: workflow)

        let preflightCallCount = await preflightProbe.callCount
        let outputExecutionCount = await outputProbe.executionCount
        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(preflightCallCount, 1)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(outputExecutionCount, 0)
        XCTAssertEqual(storeSnapshot.materializeCount, 1)
        XCTAssertEqual(storeSnapshot.deleteCount, 1)
        XCTAssertTrue(storeSnapshot.receipts.isEmpty)
        let temporaryURL = storeSnapshot.lastMaterializedURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryURL).path)
        )
    }

    func testManualRetryRecordsFailedAudioRecoveryTrigger() async throws {
        let workflow = makeWorkflow()
        let failedAudioReceipt = makeReceipt(workflowID: workflow.id)
        let recoveryStore = RecoveryControllerStoreProbe(receipt: failedAudioReceipt)
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let runReceiptRepository = InMemoryWorkflowRunReceiptRepository()
        let runReceiptRecorder = WorkflowRunReceiptRecorder(
            repository: runReceiptRepository,
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [RecoveryControllerRecognizer(shouldFail: false)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics,
            runReceiptRecorder: runReceiptRecorder
        )
        let privacyGate = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in true },
            destinationClassifier: { _ in .classified([.localSpeech]) }
        )
        let controller = makeTestFailedAudioRecoveryController(
            store: recoveryStore,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: privacyGate,

            privacyContextProvider: { makeRecoveryPrivacyContext() },
            authorizedContextProvider: { decision in
                makeRecoveryPrivacyContext().applying(decision)
            },
            recognitionOptionsProvider: { _, _ in .empty },
            currentDate: { Date(timeIntervalSince1970: 101) }
        )
        try await controller.refresh(isEnabled: true)

        let result = try await controller.retry(
            id: failedAudioReceipt.id,
            workflow: workflow
        )

        XCTAssertEqual(result, .completed)
        let receipts = try await runReceiptRepository.receipts(matching: .all)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipt.workflowID, workflow.id)
        XCTAssertEqual(receipt.trigger, .failedAudioRecovery)
        XCTAssertEqual(receipt.termination, .completed)
        XCTAssertTrue(receipt.actionDetails.isEmpty)
    }

    func testOnlyOneDecryptedRecoveryRetryCanRunAtATime() async throws {
        let workflow = makeWorkflow()
        let firstReceipt = makeReceipt(workflowID: workflow.id)
        let secondReceipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(
            receipt: firstReceipt,
            additionalReceipts: [secondReceipt]
        )
        let preflight = BlockingRecoveryPreflightProbe()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            runPreflight: { _ in await preflight.run() }
        )
        try await controller.refresh(isEnabled: true)

        let firstRetry = Task {
            try await controller.retry(id: firstReceipt.id, workflow: workflow)
        }
        await preflight.waitUntilStarted()
        do {
            _ = try await controller.retry(id: secondReceipt.id, workflow: workflow)
            XCTFail("Expected a concurrent recovery retry to be rejected.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .retryAlreadyRunning)
        }
        await preflight.release()

        let firstResult = try await firstRetry.value
        XCTAssertEqual(firstResult, .completed)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.materializeCount, 1)
        XCTAssertEqual(snapshot.receipts, [secondReceipt])
    }

    func testPreflightFailureOccursBeforeAudioIsDecryptedAndKeepsReceipt() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            runPreflight: { _ in throw RecoveryControllerTestError.failed }
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected preflight failure.")
        } catch is RecoveryControllerTestError {
            // Expected.
        }

        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(storeSnapshot.materializeCount, 0)
        XCTAssertEqual(storeSnapshot.deleteCount, 0)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
    }

    func testRecognitionFailureKeepsEncryptedReceiptAndCleansDecryptedTemporaryFile() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: true
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected recovery retry failure.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .retryFailed)
        }

        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(storeSnapshot.deleteCount, 0)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
        let temporaryURL = storeSnapshot.lastMaterializedURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryURL).path)
        )
    }

    func testCancelledRetryRestoresReceiptAndCleansDecryptedTemporaryFile() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            recognitionShouldCancel: true
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected recovery retry cancellation.")
        } catch is CancellationError {
            // Expected.
        }

        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(storeSnapshot.deleteCount, 0)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
        let temporaryURL = storeSnapshot.lastMaterializedURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: try XCTUnwrap(temporaryURL).path)
        )
    }

    func testApplicationShutdownWaitsUntilFailedDirectPlaintextCleanupIsProvenComplete() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let cleanupProbe = RecoveryShutdownCleanupProbe()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            recognitionShouldCancel: true,
            removeManagedRecoveryTemporaryFile: { _ in
                throw RecoveryControllerTestError.failed
            },
            cleanupRecoveryTemporaryFiles: {
                let shouldSucceed = await cleanupProbe.cleanup()
                guard shouldSucceed else { return false }
                guard let temporaryURL = await store.snapshot().lastMaterializedURL else {
                    return true
                }
                try? FileManager.default.removeItem(at: temporaryURL)
                return !FileManager.default.fileExists(atPath: temporaryURL.path)
            },
            initialMaintenanceRetryInterval: 0.01,
            maximumMaintenanceRetryInterval: 0.02
        )
        try await controller.refresh(isEnabled: true)

        let retryTask = Task {
            try await controller.retry(id: receipt.id, workflow: workflow)
        }
        await cleanupProbe.waitForCall(2)
        let retrySnapshot = await store.snapshot()
        let materializedURL = try XCTUnwrap(retrySnapshot.lastMaterializedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path))
        await cleanupProbe.resolve(call: 2, result: false)
        do {
            _ = try await retryTask.value
            XCTFail("Expected cancellation with cleanup still pending.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .retryFailedCleanupPending)
        }

        let completion = RecoveryShutdownCompletionProbe()
        let shutdownTask = Task {
            await controller.stopForApplicationShutdown()
            await completion.markCompleted()
        }
        await cleanupProbe.waitForCall(3)
        let completedAfterFirstShutdownSweep = await completion.isCompleted()
        XCTAssertFalse(completedAfterFirstShutdownSweep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path))
        await cleanupProbe.resolve(call: 3, result: false)

        await cleanupProbe.waitForCall(4)
        let completedAfterSecondShutdownSweep = await completion.isCompleted()
        XCTAssertFalse(completedAfterSecondShutdownSweep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedURL.path))
        await cleanupProbe.resolve(call: 4, result: true)
        await shutdownTask.value

        let didCompleteShutdown = await completion.isCompleted()
        XCTAssertTrue(didCompleteShutdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materializedURL.path))
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(finalSnapshot.receipts, [receipt])
        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected shutdown to keep recovery disabled.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .recoveryDisabled)
        }
    }

    func testCloudPrivacyDeclineOccursBeforeAudioIsDecrypted() async throws {
        var workflow = makeWorkflow()
        workflow.plan.setup.speechRoute?.recognizerID = "remote.recovery-test"
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let privacyGate = PrivacyRunGate(
            settingsProvider: { .defaults },
            cloudConfirmationProvider: { _, _, _ in false },
            destinationClassifier: { _ in .classified([.cloudSpeech]) }
        )
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            privacyRunGate: privacyGate
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected cloud confirmation to be declined.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudConfirmationDeclined)
        }

        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(storeSnapshot.materializeCount, 0)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
    }

    func testRetryPolicyTighteningDuringMaterializationCleansAndRestoresWithoutExecution() async throws {
        let executionProbe = RecoveryExecutionBoundaryProbe()
        let outputProbe = RecoveryOutputProbe()
        let materializationBarrier = RecoveryMaterializationBarrier()
        let settings = RecoveryMutablePrivacySettings(
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        )
        let workflow = WorkflowDefinition(
            name: "Cloud recovery final authorization",
            trigger: .manual,
            pipeline: PipelineDeclaration(
                recognizerID: "remote.recovery-boundary",
                outputActions: [OutputActionReference(id: "recovery-controller.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(
            receipt: receipt,
            materializationBarrier: materializationBarrier
        )
        let eventBus = EventBus()
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [RecoveryExecutionBoundaryRecognizer(probe: executionProbe)]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [RecoveryProbeAction(probe: outputProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        let privacyGate = PrivacyRunGate(
            settingsProvider: { await settings.read() },
            cloudConfirmationProvider: { _, _, _ in
                XCTFail("A newly blocked recovery must not request confirmation.")
                return false
            },
            destinationClassifier: { _ in .classified([.cloudSpeech]) }
        )
        let privacyContext = makeRecoveryPrivacyContext()
        let controller = makeTestFailedAudioRecoveryController(
            store: store,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: privacyGate,
            privacyContextProvider: { privacyContext },
            authorizedContextProvider: { decision in privacyContext.applying(decision) },
            recognitionOptionsProvider: { _, _ in .empty },
            runPreflight: { _ in await executionProbe.recordPreflight() },
            currentDate: { Date(timeIntervalSince1970: 101) }
        )
        try await controller.refresh(isEnabled: true)

        let retry = Task {
            try await controller.retry(id: receipt.id, workflow: workflow)
        }
        try await materializationBarrier.waitUntilEntered()
        await settings.replace(with: PrivacyPolicySettings(
            sensitiveAppRules: [
                SensitiveAppRule(
                    bundleIdentifier: "com.example.TestApp",
                    applicationName: "Test App"
                ),
            ],
            cloudConfirmationRequired: false
        ))
        await materializationBarrier.release()

        do {
            _ = try await retry.value
            XCTFail("Policy tightening during recovery materialization must block recognition.")
        } catch let error as PrivacyRunGate.GateError {
            XCTAssertEqual(error, .cloudProcessingBlocked)
        }

        let execution = await executionProbe.snapshot()
        let outputCount = await outputProbe.executionCount
        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(execution.recognition, 0)
        XCTAssertEqual(outputCount, 0)
        XCTAssertEqual(storeSnapshot.materializeCount, 1)
        XCTAssertEqual(storeSnapshot.receipts, [receipt])
        let plaintextURL = try XCTUnwrap(storeSnapshot.lastMaterializedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plaintextURL.path))
    }

    func testRetryRechecksExpirationAfterCloudConfirmation() async throws {
        var workflow = makeWorkflow()
        workflow.plan.setup.speechRoute?.recognizerID = "remote.recovery-test"
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let clock = LockedRecoveryDate(Date(timeIntervalSince1970: 199))
        let privacyGate = PrivacyRunGate(
            settingsProvider: { .defaults },
            cloudConfirmationProvider: { _, _, _ in
                clock.set(Date(timeIntervalSince1970: 201))
                return true
            },
            destinationClassifier: { _ in .classified([.cloudSpeech]) }
        )
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            privacyRunGate: privacyGate,
            currentDate: { clock.read() }
        )
        try await controller.refresh(isEnabled: true)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected the recording to expire during confirmation.")
        } catch {
            XCTAssertEqual(error as? FailedAudioRecoveryError, .expired)
        }

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.materializeCount, 0)
        XCTAssertTrue(snapshot.receipts.isEmpty)
    }

    func testCompletedRetryWithCleanupFailureCannotRepeatProviderRequest() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(
            receipt: receipt,
            deleteShouldFail: true
        )
        let controller = makeController(
            store: store,
            recognitionShouldFail: false
        )
        try await controller.refresh(isEnabled: true)

        let result = try await controller.retry(id: receipt.id, workflow: workflow)
        XCTAssertEqual(result, .completedCleanupPending)

        let firstSnapshot = await store.snapshot()
        XCTAssertEqual(firstSnapshot.materializeCount, 1)
        XCTAssertEqual(firstSnapshot.receipts.count, 1)
        XCTAssertFalse(firstSnapshot.receipts[0].status.canRetry)

        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected the interrupted retry state to block repetition.")
        } catch {
            XCTAssertEqual(error as? FailedAudioRecoveryError, .retryOutcomeUnknown)
        }
        let secondSnapshot = await store.snapshot()
        XCTAssertEqual(secondSnapshot.materializeCount, 1)
    }

    func testEnabledControllerPurgesAtEarliestExpirationDeadline() async throws {
        try await assertExpirationCleanup(failureCount: 0)
    }

    func testExpirationCleanupRetriesAfterTransientFailure() async throws {
        try await assertExpirationCleanup(failureCount: 1)
    }

    private func assertExpirationCleanup(failureCount: Int) async throws {
        let workflow = makeWorkflow()
        let now = Date(timeIntervalSince1970: 100)
        let clock = LockedRecoveryDate(now)
        var receipt = makeReceipt(workflowID: workflow.id)
        receipt.createdAt = now.addingTimeInterval(-1)
        receipt.expiresAt = now.addingTimeInterval(0.05)
        let store = RecoveryControllerStoreProbe(receipt: receipt, purgeFailureCount: failureCount)
        let eventBus = EventBus()
        let (completed, observation) = await observeRecoveryEvent(on: eventBus) { event in
            if case .failedAudioRecoveryUpdated(let receipts) = event { return receipts.isEmpty }
            return false
        }
        defer { observation.cancel() }
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            eventBus: eventBus,
            currentDate: { clock.read() },
            initialMaintenanceRetryInterval: 0.02,
            maximumMaintenanceRetryInterval: 0.04
        )

        try await controller.refresh(isEnabled: true)
        clock.set(receipt.expiresAt)
        await fulfillment(of: [completed], timeout: 5)

        let snapshot = await store.snapshot()
        XCTAssertGreaterThanOrEqual(snapshot.purgeCount, failureCount + 1)
        XCTAssertTrue(snapshot.receipts.isEmpty)
    }

    func testApplicationShutdownDrainsInFlightExpirationPurgeWithoutRescheduling() async throws {
        let workflow = makeWorkflow()
        let now = Date()
        var receipt = makeReceipt(workflowID: workflow.id)
        receipt.createdAt = now.addingTimeInterval(-1)
        receipt.expiresAt = now.addingTimeInterval(0.02)
        let purgeBarrier = RecoveryMaterializationBarrier()
        let cleanupProbe = RecoveryTemporaryCleanupProbe(failureCount: 0)
        let store = RecoveryControllerStoreProbe(
            receipt: receipt,
            purgeBarrier: purgeBarrier
        )
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            currentDate: { Date() },
            cleanupRecoveryTemporaryFiles: { await cleanupProbe.cleanup() },
            initialMaintenanceRetryInterval: 0.01,
            maximumMaintenanceRetryInterval: 0.02
        )
        try await controller.refresh(isEnabled: true)
        try await purgeBarrier.waitUntilEntered()

        let completion = RecoveryShutdownCompletionProbe()
        let shutdownTask = Task {
            await controller.stopForApplicationShutdown()
            await completion.markCompleted()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        let completedWhilePurgeWasBlocked = await completion.isCompleted()
        let cleanupAttemptsWhilePurgeWasBlocked = await cleanupProbe.attemptCount
        XCTAssertFalse(completedWhilePurgeWasBlocked)
        XCTAssertEqual(cleanupAttemptsWhilePurgeWasBlocked, 1)

        await purgeBarrier.release()
        await shutdownTask.value
        try await Task.sleep(for: .milliseconds(80))

        let snapshot = await store.snapshot()
        let finalCleanupAttemptCount = await cleanupProbe.attemptCount
        let didCompleteShutdown = await completion.isCompleted()
        XCTAssertEqual(snapshot.purgeCount, 1)
        XCTAssertEqual(finalCleanupAttemptCount, 2)
        XCTAssertTrue(didCompleteShutdown)
    }

    func testFailedClearRestoresEnabledPreservationLatch() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(
            receipt: receipt,
            deleteAllShouldFail: true
        )
        let controller = makeController(
            store: store,
            recognitionShouldFail: false
        )
        try await controller.refresh(isEnabled: true)

        do {
            try await controller.deleteAll()
            XCTFail("Expected clear to report its storage failure.")
        } catch {
            XCTAssertEqual(error as? FailedAudioRecoveryError, .storageUnavailable)
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-recovery-clear-failure-\(UUID().uuidString).wav"
        )
        try Data([1]).write(to: fileURL)
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        defer { _ = try? audio.removeManagedTemporaryFile() }
        let preserved = try await controller.preserveIfEnabled(
            audio: audio,
            originalRunID: UUID(),
            workflowID: workflow.id,
            failure: WorkflowRunFailureSummary(
                runID: UUID(),
                stage: .recognizing,
                code: .processing
            )
        )

        XCTAssertNotNil(preserved)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.preserveCount, 1)
        XCTAssertEqual(snapshot.receipts.count, 2)
    }

    func testPlaintextCleanupFailureRetriesAndBlocksNewRecoveryRetry() async throws {
        try await assertPlaintextCleanupBlocksRetry(isEnabled: false)
    }

    func testEnabledStartupReconcilesCrashPlaintextBeforeAllowingRetry() async throws {
        try await assertPlaintextCleanupBlocksRetry(isEnabled: true)
    }

    private func assertPlaintextCleanupBlocksRetry(isEnabled: Bool) async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let successBarrier = RecoveryMaterializationBarrier()
        let cleanupProbe = RecoveryTemporaryCleanupProbe(
            failureCount: 2,
            successBarrier: successBarrier
        )
        let eventBus = EventBus()
        let (completed, observation) = await observeRecoveryEvent(on: eventBus) { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.event == "audio-recovery.plaintext-cleanup-completed"
            }
            return false
        }
        defer { observation.cancel() }
        let controller = makeController(
            store: store,
            recognitionShouldFail: false,
            eventBus: eventBus,
            cleanupRecoveryTemporaryFiles: { await cleanupProbe.cleanup() },
            initialMaintenanceRetryInterval: 0.01,
            maximumMaintenanceRetryInterval: 0.02
        )

        if isEnabled {
            try await controller.refresh(isEnabled: true)
        } else {
            do {
                try await controller.refresh(isEnabled: false)
                XCTFail("Expected the initial plaintext sweep to fail.")
            } catch let error as FailedAudioRecoveryController.ControllerError {
                XCTAssertEqual(error, .plaintextCleanupPending)
            }
        }
        try await successBarrier.waitUntilEntered()
        do {
            _ = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTFail("Expected pending plaintext cleanup to block retry.")
        } catch let error as FailedAudioRecoveryController.ControllerError {
            XCTAssertEqual(error, .plaintextCleanupPending)
        }

        await successBarrier.release()
        await fulfillment(of: [completed], timeout: 5)
        let attemptCount = await cleanupProbe.attemptCount
        XCTAssertEqual(attemptCount, 3)
        if isEnabled {
            let result = try await controller.retry(id: receipt.id, workflow: workflow)
            XCTAssertEqual(result, .completed)
        }
    }

    func testOptOutWaitsForInFlightPreserveAndPerformsFinalSweep() async throws {
        let workflow = makeWorkflow()
        let store = BlockingPreserveRecoveryStore()
        let controller = makeController(
            store: store,
            recognitionShouldFail: false
        )
        try await controller.refresh(isEnabled: true)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-recovery-opt-out-\(UUID().uuidString).wav"
        )
        try Data([1]).write(to: fileURL)
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        defer { _ = try? audio.removeManagedTemporaryFile() }
        let failure = WorkflowRunFailureSummary(
            runID: UUID(),
            stage: .recognizing,
            code: .processing
        )

        let preserveTask = Task {
            try await controller.preserveIfEnabled(
                audio: audio,
                originalRunID: UUID(),
                workflowID: workflow.id,
                failure: failure
            )
        }
        await store.waitUntilPreserveStarts()
        let disableTask = Task {
            try await controller.refresh(isEnabled: false)
        }
        await store.waitUntilDeleteAllStarts()
        await store.releasePreserve()

        let preservedReceipt = try await preserveTask.value
        try await disableTask.value
        let snapshot = await store.snapshot()
        XCTAssertNil(preservedReceipt)
        XCTAssertTrue(snapshot.receipts.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.deleteAllCount, 2)
    }

    func testStaleEnableRefreshCannotOverrideNewerOptOut() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = BlockingRefreshRecoveryStore(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: false
        )

        let staleEnable = Task {
            try await controller.refresh(isEnabled: true)
        }
        await store.waitUntilReceiptsStarts()
        try await controller.refresh(isEnabled: false)
        await store.releaseReceipts()
        try await staleEnable.value

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-recovery-stale-enable-\(UUID().uuidString).wav"
        )
        try Data([1]).write(to: fileURL)
        let audio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        defer { _ = try? audio.removeManagedTemporaryFile() }
        let preserved = try await controller.preserveIfEnabled(
            audio: audio,
            originalRunID: UUID(),
            workflowID: workflow.id,
            failure: WorkflowRunFailureSummary(
                runID: UUID(),
                stage: .recognizing,
                code: .processing
            )
        )

        XCTAssertNil(preserved)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.preserveCount, 0)
        XCTAssertGreaterThanOrEqual(snapshot.deleteAllCount, 2)
    }

    func testDisabledStartupRefreshClearsArtifactsWithoutStartingRecognition() async throws {
        let workflow = makeWorkflow()
        let receipt = makeReceipt(workflowID: workflow.id)
        let store = RecoveryControllerStoreProbe(receipt: receipt)
        let controller = makeController(
            store: store,
            recognitionShouldFail: false
        )

        try await controller.refresh(
            isEnabled: false,
            now: Date(timeIntervalSince1970: 101)
        )

        let storeSnapshot = await store.snapshot()
        XCTAssertEqual(storeSnapshot.deleteAllCount, 2)
        XCTAssertEqual(storeSnapshot.materializeCount, 0)
        XCTAssertTrue(storeSnapshot.receipts.isEmpty)
    }

    private func observeRecoveryEvent(
        on eventBus: EventBus,
        matching predicate: @escaping @Sendable (RillEvent) -> Bool
    ) async -> (XCTestExpectation, Task<Void, Never>) {
        let completed = expectation(description: "Recovery state committed")
        let events = await eventBus.stream()
        let observation = Task {
            for await event in events {
                if predicate(event) {
                    completed.fulfill()
                    return
                }
            }
        }
        return (completed, observation)
    }

    private func makeController(
        store: any FailedAudioRecoveryStore,
        recognitionShouldFail: Bool,
        recognitionShouldCancel: Bool = false,
        eventBus: EventBus = EventBus(),
        outputProbe: RecoveryOutputProbe = RecoveryOutputProbe(),
        privacyRunGate: PrivacyRunGate? = PrivacyRunGate(
            settingsProvider: {
                PrivacyPolicySettings(
                    sensitiveAppRules: [],
                    cloudConfirmationRequired: false
                )
            },
            cloudConfirmationProvider: { _, _, _ in true },
            destinationClassifier: { _ in .classified([.localSpeech]) }
        ),
        runPreflight: @escaping RecognitionRunPreflight = { _ in },
        currentDate: @escaping @Sendable () -> Date = {
            Date(timeIntervalSince1970: 101)
        },
        removeManagedRecoveryTemporaryFile: @escaping @Sendable (CapturedAudio) throws -> Void = {
            _ = try $0.removeManagedTemporaryFile()
        },
        cleanupRecoveryTemporaryFiles: @escaping @Sendable () async -> Bool = { true },
        initialMaintenanceRetryInterval: TimeInterval = 5,
        maximumMaintenanceRetryInterval: TimeInterval = 5 * 60
    ) -> FailedAudioRecoveryController {
        let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(
                recognizers: [
                    RecoveryControllerRecognizer(
                        shouldFail: recognitionShouldFail,
                        shouldCancel: recognitionShouldCancel
                    ),
                ]
            ),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(
                actions: [RecoveryProbeAction(probe: outputProbe)]
            ),
            candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
            eventBus: eventBus,
            diagnostics: diagnostics
        )
        return makeTestFailedAudioRecoveryController(
            store: store,
            sessionCoordinator: coordinator,
            eventBus: eventBus,
            diagnostics: diagnostics,
            privacyRunGate: privacyRunGate,

            privacyContextProvider: { makeRecoveryPrivacyContext() },
            authorizedContextProvider: { decision in
                makeRecoveryPrivacyContext().applying(decision)
            },
            recognitionOptionsProvider: { _, _ in .empty },
            runPreflight: runPreflight,
            currentDate: currentDate,
            removeManagedRecoveryTemporaryFile: removeManagedRecoveryTemporaryFile,
            cleanupRecoveryTemporaryFiles: cleanupRecoveryTemporaryFiles,
            initialMaintenanceRetryInterval: initialMaintenanceRetryInterval,
            maximumMaintenanceRetryInterval: maximumMaintenanceRetryInterval
        )
    }

    private func makeWorkflow() -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Recovery Workflow",
            pipeline: PipelineDeclaration(
                recognizerID: "context.selection",
                outputActions: [OutputActionReference(id: "recovery-controller.action")]
            ),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
    }

    private func makeReceipt(workflowID: UUID) -> FailedAudioRecoveryReceipt {
        FailedAudioRecoveryReceipt(
            originalRunID: UUID(),
            workflowID: workflowID,
            createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200),
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            plaintextByteCount: 3,
            failureStage: .recognizing,
            failureCode: .processing
        )
    }
}

private func makeRecoveryPrivacyContext() -> ContextSnapshot {
    ContextSnapshot(
        focus: FocusSnapshot(
            applicationName: "Test App",
            bundleIdentifier: "com.example.TestApp",
            processIdentifier: 1,
            focusedRole: nil,
            selectedText: "",
            secureInput: false
        ),
        clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 1)
    )
}
