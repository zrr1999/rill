import Foundation
import VoxTypeCore
import VoxTypeProviders
import VoxTypeRuntime

actor DeepgramAudioTestController {
    enum TestError: Error, LocalizedError, Equatable {
        case alreadyRecording
        case notRecording

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A Deepgram audio test recording is already in progress."
            case .notRecording:
                return "No Deepgram audio test recording is currently active."
            }
        }
    }

    private enum State: Sendable, Equatable {
        case idle
        case recording(UUID)
    }

    private let audioCaptureService: any AudioCaptureService
    private let diagnostics: DiagnosticsRecorder?
    private var state: State = .idle

    init(
        audioCaptureService: any AudioCaptureService,
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        self.audioCaptureService = audioCaptureService
        self.diagnostics = diagnostics
    }

    func startTest(settings: DeepgramSettings) async throws {
        guard case .idle = state else {
            throw TestError.alreadyRecording
        }

        let runID = UUID()
        let workflow = Self.testWorkflow(settings: settings)
        let triggerEvent = WorkflowTriggerEvent(
            binding: .menuBar,
            workflowID: workflow.id,
            sourceID: "settings.deepgram-test"
        )
        let request = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            triggerEvent: triggerEvent,
            preferredFormat: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            metadata: ["source": "settings.deepgram-test"]
        )

        try await audioCaptureService.startCapture(request)
        state = .recording(runID)
        await recordDiagnostic(
            level: .info,
            event: "provider.deepgram.test.recording.started",
            message: "Started a Deepgram settings-page audio test recording.",
            runID: runID
        )
    }

    func finishTest(settings: DeepgramSettings) async throws -> RecognitionResult {
        guard case .recording(let runID) = state else {
            throw TestError.notRecording
        }

        let workflow = Self.testWorkflow(settings: settings)
        state = .idle

        do {
            let capturedAudio = try await audioCaptureService.finishCapture()
            defer { cleanupCapturedAudio(capturedAudio) }

            let recognizer = DeepgramRecognizer(
                configuration: .init(
                    apiKey: settings.apiKey.nonEmpty,
                    baseURL: settings.baseURL,
                    model: settings.model,
                    language: settings.language.nonEmpty
                )
            )
            let result = try await recognizer.recognize(
                RecognitionRequest(
                    runID: runID,
                    workflow: workflow,
                    contextSnapshot: .empty,
                    triggerEvent: WorkflowTriggerEvent(
                        binding: .menuBar,
                        workflowID: workflow.id,
                        sourceID: "settings.deepgram-test"
                    ),
                    capturedAudio: capturedAudio
                )
            )
            await recordDiagnostic(
                level: .info,
                event: "provider.deepgram.test.completed",
                message: "Completed a Deepgram settings-page audio test.",
                runID: runID
            )
            return result
        } catch {
            await recordDiagnostic(
                level: .error,
                event: "provider.deepgram.test.failed",
                message: error.localizedDescription,
                runID: runID
            )
            throw error
        }
    }

    func cancelTest() async {
        await audioCaptureService.cancelCapture()
        state = .idle
    }

    private func recordDiagnostic(
        level: DiagnosticLevel,
        event: String,
        message: String,
        runID: UUID
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .providers,
                level: level,
                event: event,
                message: message
            )
        )
    }

    private func cleanupCapturedAudio(_ capturedAudio: CapturedAudio) {
        if let fileURL = capturedAudio.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func testWorkflow(settings: DeepgramSettings) -> WorkflowDefinition {
        WorkflowDefinition(
            name: "Deepgram Connection Check",
            pipeline: PipelineDeclaration(
                recognizerID: "deepgram.prerecorded",
                outputActions: []
            ),
            ui: WorkflowUIConfig(symbolName: "waveform.badge.mic", accentColorName: "cyan"),
            metadata: [
                "provider": "deepgram",
                "deepgram.model": settings.model,
                "recognizer.language": settings.language,
            ]
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
