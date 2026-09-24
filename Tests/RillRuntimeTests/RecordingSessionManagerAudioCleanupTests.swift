
@testable import RillCore
@testable import RillWorkflows
import Foundation
import XCTest
@testable import RillPlatform

private actor DeferredFinishAudioCaptureService: AudioCaptureService {
    private let capturedAudio: CapturedAudio
    private var finishStarted = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(capturedAudio: CapturedAudio) {
        self.capturedAudio = capturedAudio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {}

    func finishCapture() async throws -> CapturedAudio {
        capturedAudio
    }

    func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
        finishStarted = true
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        return .resolved(capturedAudio)
    }

    func cancelCapture() async {}

    func waitUntilFinishStarts() async {
        while !finishStarted {
            await Task.yield()
        }
    }

    func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor TransferredRecordingCaptureService: AudioCaptureService {
    private let capturedAudio: CapturedAudio
    private var activeRunID: UUID?
    private var didTransfer = false
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []

    init(capturedAudio: CapturedAudio) {
        self.capturedAudio = capturedAudio
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {
        activeRunID = request.runID
    }

    func finishCapture() async throws -> CapturedAudio {
        activeRunID = nil
        return capturedAudio
    }

    func finishCaptureDeferred() async throws -> DeferredCapturedAudio {
        activeRunID = nil
        didTransfer = true
        let waiters = transferWaiters
        transferWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return .resolved(capturedAudio)
    }

    func cancelCapture() async {
        activeRunID = nil
    }

    func cancelCapture(runID: UUID) async {
        guard activeRunID == runID else { return }
        activeRunID = nil
    }

    func waitUntilTransferred() async {
        guard !didTransfer else { return }
        await withCheckedContinuation { continuation in
            transferWaiters.append(continuation)
        }
    }
}

private actor RecordingSealGate {
    private var isArmed = false
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() {
        isArmed = true
    }

    func read() async -> ContextSnapshot {
        guard isArmed else { return .empty }
        isArmed = false
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return .empty
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor RecordingCancellationCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private struct RecordingCleanupContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

final class RecordingSessionManagerAudioCleanupTests: XCTestCase {
    func testCancellationDuringDeferredFinishDiscardsManagedTemporaryFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-recording-cancel-" + UUID().uuidString + ".wav")
        try Data([0x00]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let captureService = DeferredFinishAudioCaptureService(capturedAudio: capturedAudio)
        let workflow = WorkflowDefinition(
            name: "Recording Cleanup",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "unused", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let eventBus = EventBus()
        let coordinator = SessionCoordinator(
            contextProvider: RecordingCleanupContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: captureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: CapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            eventBus: eventBus,
            privacyRunGate: PrivacyRunGate(
                settingsProvider: {
                    PrivacyPolicySettings(
                        sensitiveAppRules: [],
                        cloudConfirmationRequired: false
                    )
                },
                cloudConfirmationProvider: { _, _, _ in true },
                destinationClassifier: { _ in .classified([.localSpeech]) }
            ),
            workflowProvider: { [workflow] }
        )

        await manager.beginPushToTalk()
        let finishTask = Task {
            await manager.endPushToTalk()
        }
        await captureService.waitUntilFinishStarts()

        let cancellationTask = Task {
            await manager.cancelCurrentRecording()
        }
        await Task.yield()
        await captureService.resumeFinish()
        await cancellationTask.value
        await finishTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCancellationWaitsForTransferredCaptureCleanupBeforeReturning() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-recording-transferred-" + UUID().uuidString + ".wav")
        try Data([0x00]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let capturedAudio = try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
        let captureService = TransferredRecordingCaptureService(capturedAudio: capturedAudio)
        let sealGate = RecordingSealGate()
        let workflow = WorkflowDefinition(
            name: "Transferred Recording Cleanup",
            trigger: .hotkey,
            pipeline: PipelineDeclaration(recognizerID: "unused", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )
        let eventBus = EventBus()
        let coordinator = SessionCoordinator(
            contextProvider: RecordingCleanupContextProvider(),
            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = CapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let manager = RecordingSessionManager(
            audioCaptureService: captureService,
            hotkeyTap: HotkeyEventTap(),
            capturedAudioProcessingQueue: queue,
            eventBus: eventBus,
            privacyRunGate: PrivacyRunGate(
                settingsProvider: {
                    PrivacyPolicySettings(
                        sensitiveAppRules: [],
                        cloudConfirmationRequired: false
                    )
                },
                cloudConfirmationProvider: { _, _, _ in true },
                destinationClassifier: { _ in .classified([.localSpeech]) }
            ),
            workflowProvider: { [workflow] },
            privacyContextProvider: { await sealGate.read() },
            authorizedContextProvider: { _ in await sealGate.read() },
            liveAuthorizationMonitorInterval: .seconds(60)
        )

        await manager.beginPushToTalk()
        await sealGate.arm()
        let finishTask = Task {
            await manager.endPushToTalk()
        }
        await captureService.waitUntilTransferred()
        await sealGate.waitUntilEntered()

        let completion = RecordingCancellationCompletionProbe()
        let cancellationTask = Task {
            await manager.cancelCurrentRecording()
            await completion.markCompleted()
        }
        await Task.yield()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let didCompleteBeforeRelease = await completion.isCompleted()
        XCTAssertFalse(didCompleteBeforeRelease)

        await sealGate.release()
        await cancellationTask.value
        await finishTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let didCompleteAfterRelease = await completion.isCompleted()
        XCTAssertTrue(didCompleteAfterRelease)
        await queue.shutdown()
    }
}
