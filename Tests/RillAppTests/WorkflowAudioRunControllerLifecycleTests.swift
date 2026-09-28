@testable import RillWorkflows
import RillPlatform
import RillDomainTestSupport
import Foundation
import XCTest
@testable import RillCore

private actor ManagedFileAudioCaptureService: AudioCaptureService {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func startCapture(_ request: AudioCaptureRequest) async throws {}

    func finishCapture() async throws -> CapturedAudio {
        try CapturedAudio(
            durationSeconds: 1,
            format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            fileURL: fileURL,
            fileOwnership: .managedTemporary
        )
    }

    func cancelCapture() async {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct WorkflowAudioCleanupContextProvider: ContextProvider {
    func captureContext() async -> ContextSnapshot { .empty }
}

private actor WorkflowManagedAudioRemovalProbe {
    private enum ProbeError: Error { case transient }
    private var attempts = 0

    func remove(_ fileURL: URL) throws {
        attempts += 1
        if attempts == 1 { throw ProbeError.transient }
        try FileManager.default.removeItem(at: fileURL)
    }

    func count() -> Int { attempts }
}

final class WorkflowAudioRunControllerLifecycleTests: XCTestCase {
    func testRejectedQueueTransferRetriesControllerOwnedFileRemoval() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let captureService = ManagedFileAudioCaptureService(fileURL: fileURL)
        let eventBus = EventBus()
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeTestCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        await queue.shutdown()
        let removalProbe = WorkflowManagedAudioRemovalProbe()
        let cleanupOwner = ManagedTemporaryAudioCleanupOwner(
            removal: { try await removalProbe.remove($0) },
            initialRetryDelay: .milliseconds(1),
            maximumRetryDelay: .milliseconds(1),
            sleep: { _ in }
        )
        let controller = makeTestWorkflowAudioRunController(
            audioCaptureService: captureService,
            capturedAudioProcessingQueue: queue,
            privacyRunGate: makeWorkflowAudioLifecycleTestPrivacyGate(),
            cleanupOwner: cleanupOwner
        )
        let workflow = WorkflowDefinition(
            name: "Rejected Queue Cleanup",
            trigger: .manual,
            pipeline: PipelineDeclaration(recognizerID: "missing", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )

        try await controller.startRun(workflow: workflow, binding: .manual)
        try await controller.finishRun()

        let attempts = await removalProbe.count()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFinishedRunTransfersManagedTemporaryFileToQueueForCleanup() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let captureService = ManagedFileAudioCaptureService(fileURL: fileURL)
        let eventBus = EventBus()
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let queue = makeTestCapturedAudioProcessingQueue(
            sessionCoordinator: coordinator,
            eventBus: eventBus
        )
        let controller = makeTestWorkflowAudioRunController(
            audioCaptureService: captureService,
            capturedAudioProcessingQueue: queue,
            privacyRunGate: makeWorkflowAudioLifecycleTestPrivacyGate()
        )
        let workflow = WorkflowDefinition(
            name: "Manual Audio Cleanup",
            trigger: .manual,
            pipeline: PipelineDeclaration(recognizerID: "missing", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )

        try await controller.startRun(workflow: workflow, binding: .manual)
        try await controller.finishRun()

        for _ in 0..<200 {
            if await queue.pendingCount == 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCancelledRunLeavesCleanupWithCaptureService() async throws {
        let fileURL = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let captureService = ManagedFileAudioCaptureService(fileURL: fileURL)
        let eventBus = EventBus()
        let coordinator = makeTestSessionCoordinator(

            recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
            transformerRegistry: TextTransformerRegistry(transformers: []),
            actionRegistry: OutputActionRegistry(actions: []),
            candidateResolver: CandidateResolver(eventBus: eventBus),
            eventBus: eventBus
        )
        let controller = makeTestWorkflowAudioRunController(
            audioCaptureService: captureService,
            capturedAudioProcessingQueue: makeTestCapturedAudioProcessingQueue(
                sessionCoordinator: coordinator,
                eventBus: eventBus
            ),
            privacyRunGate: makeWorkflowAudioLifecycleTestPrivacyGate()
        )
        let workflow = WorkflowDefinition(
            name: "Cancelled Audio Cleanup",
            trigger: .manual,
            pipeline: PipelineDeclaration(recognizerID: "missing", outputActions: []),
            ui: WorkflowUIConfig(symbolName: "waveform", accentColorName: "blue")
        )

        try await controller.startRun(workflow: workflow, binding: .manual)
        await controller.cancelRun()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeAudioFile() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rill-manual-lifecycle-" + UUID().uuidString + ".wav")
        try Data([0x00]).write(to: fileURL)
        return fileURL
    }
}

private func makeWorkflowAudioLifecycleTestPrivacyGate() -> PrivacyRunGate {
    PrivacyRunGate(
        settingsProvider: {
            PrivacyPolicySettings(
                sensitiveAppRules: [],
                cloudConfirmationRequired: false
            )
        },
        cloudConfirmationProvider: { _, _, _ in true },
        destinationClassifier: { _ in .classified([.localSpeech]) }
    )
}
