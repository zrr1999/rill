import Foundation
import RillCore
import RillProviders
import RillRuntime

actor DeepgramAudioTestController {
    enum TestError: Error, LocalizedError, Equatable {
        case alreadyRecording
        case notRecording
        case configurationChanged
        case shuttingDown

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A Deepgram audio test recording is already in progress."
            case .notRecording:
                return "No Deepgram audio test recording is currently active."
            case .configurationChanged:
                return "Deepgram settings changed after the diagnostic recording started."
            case .shuttingDown:
                return "Deepgram audio testing is shutting down."
            }
        }
    }

    private enum Lifecycle: Sendable, Equatable {
        case accepting
        case shuttingDown
        case terminated
    }

    private enum State: Sendable, Equatable {
        case idle
        case preparing(UUID)
        case recording(UUID, DeepgramSettings)
        case finishing(UUID, DeepgramSettings, cancelled: Bool)
        case cancelling(UUID)
    }

    private struct FinishingOperation {
        let id: UUID
        let runID: UUID
        let task: Task<RecognitionResult, Error>
    }

    private let audioCaptureService: any AudioCaptureService
    private let diagnostics: DiagnosticsRecorder?
    private let configurationPreflight: @Sendable (DeepgramSettings) async throws -> Void
    private let privacyPreflight: @Sendable (WorkflowDefinition) async throws -> Void
    private let privacyAuthorization: @Sendable (WorkflowDefinition) async throws -> Void
    private let recognize: @Sendable (
        DeepgramSettings,
        RecognitionRequest
    ) async throws -> RecognitionResult
    private let cleanupOwner: ManagedTemporaryAudioCleanupOwner
    private var state: State = .idle
    private var finishingOperation: FinishingOperation?
    private var lifecycle: Lifecycle = .accepting
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var diagnosticTailTask: Task<Void, Never>?
    private var diagnosticQueueSealed = false

    init(
        audioCaptureService: any AudioCaptureService,
        diagnostics: DiagnosticsRecorder? = nil,
        configurationPreflight: @escaping @Sendable (
            DeepgramSettings
        ) async throws -> Void = { settings in
            _ = try DeepgramConfigurationValidator.validate(
                DeepgramRecognizer.Configuration(
                    apiKey: settings.apiKey.nonEmpty,
                    baseURL: settings.baseURL,
                    model: settings.model,
                    language: settings.language.nonEmpty
                )
            )
        },
        privacyPreflight: @escaping @Sendable (
            WorkflowDefinition
        ) async throws -> Void = { _ in
            throw PrivacyRunGate.GateError.settingsUnavailable
        },
        privacyAuthorization: @escaping @Sendable (
            WorkflowDefinition
        ) async throws -> Void = { _ in
            throw PrivacyRunGate.GateError.settingsUnavailable
        },
        recognize: @escaping @Sendable (
            DeepgramSettings,
            RecognitionRequest
        ) async throws -> RecognitionResult = { settings, request in
            let recognizer = DeepgramRecognizer(
                configuration: .init(
                    apiKey: settings.apiKey.nonEmpty,
                    baseURL: settings.baseURL,
                    model: settings.model,
                    language: settings.language.nonEmpty
                )
            )
            return try await recognizer.recognize(request)
        },
        cleanupOwner: ManagedTemporaryAudioCleanupOwner = ManagedTemporaryAudioCleanupOwner()
    ) {
        self.audioCaptureService = audioCaptureService
        self.diagnostics = diagnostics
        self.configurationPreflight = configurationPreflight
        self.privacyPreflight = privacyPreflight
        self.privacyAuthorization = privacyAuthorization
        self.recognize = recognize
        self.cleanupOwner = cleanupOwner
    }

    func startTest(settings: DeepgramSettings) async throws {
        guard lifecycle == .accepting else {
            throw TestError.shuttingDown
        }
        guard case .idle = state else {
            throw TestError.alreadyRecording
        }

        let runID = UUID()
        state = .preparing(runID)
        let workflow = Self.diagnosticWorkflow
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

        do {
            try await configurationPreflight(settings)
            guard lifecycle == .accepting, state == .preparing(runID) else {
                throw CancellationError()
            }
            try await privacyPreflight(workflow)
            guard lifecycle == .accepting, state == .preparing(runID) else {
                throw CancellationError()
            }
            try await audioCaptureService.startCapture(request)
            guard lifecycle == .accepting, state == .preparing(runID) else {
                await audioCaptureService.cancelCapture(runID: runID)
                throw CancellationError()
            }
            state = .recording(runID, settings)
        } catch {
            if state == .preparing(runID) {
                state = .idle
            }
            throw error
        }
        enqueueDiagnostic(
            level: .info,
            event: "provider.deepgram.test.recording.started",
            message: "Started a Deepgram settings-page audio test recording.",
            runID: runID
        )
    }

    func finishTest(settings: DeepgramSettings) async throws -> RecognitionResult {
        guard case .recording(let runID, let authorizedSettings) = state else {
            throw TestError.notRecording
        }
        guard settings == authorizedSettings else {
            state = .cancelling(runID)
            await audioCaptureService.cancelCapture(runID: runID)
            if state == .cancelling(runID) {
                state = .idle
            }
            throw TestError.configurationChanged
        }

        let workflow = Self.diagnosticWorkflow
        state = .finishing(runID, authorizedSettings, cancelled: false)

        let operationID = UUID()
        let audioCaptureService = self.audioCaptureService
        let privacyAuthorization = self.privacyAuthorization
        let recognize = self.recognize
        let cleanupOwner = self.cleanupOwner
        let operation = FinishingOperation(
            id: operationID,
            runID: runID,
            task: Task {
                let capturedAudio = try await audioCaptureService.finishCapture()
                do {
                    try Task.checkCancellation()

                    try await privacyAuthorization(workflow)
                    try Task.checkCancellation()

                    let recognitionRequest = RecognitionRequest(
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
                    let result = try await recognize(authorizedSettings, recognitionRequest)
                    try Task.checkCancellation()
                    await Self.removeManagedTemporaryAudio(
                        capturedAudio,
                        runID: runID,
                        cleanupOwner: cleanupOwner
                    )
                    return result
                } catch {
                    await Self.removeManagedTemporaryAudio(
                        capturedAudio,
                        runID: runID,
                        cleanupOwner: cleanupOwner
                    )
                    throw error
                }
            }
        )
        finishingOperation = operation

        do {
            let result = try await operation.task.value
            guard ownsFinishingOperation(operation),
                  state == .finishing(runID, authorizedSettings, cancelled: false) else {
                throw CancellationError()
            }
            clearFinishingOperation(operation)
            state = .idle
            enqueueDiagnostic(
                level: .info,
                event: "provider.deepgram.test.completed",
                message: "Completed a Deepgram settings-page audio test.",
                runID: runID
            )
            return result
        } catch {
            clearFinishingOperation(operation)
            if case .finishing(let currentRunID, _, _) = state,
               currentRunID == runID {
                state = .idle
            }
            enqueueDiagnostic(
                level: .error,
                event: "provider.deepgram.test.failed",
                message: "The Deepgram settings-page audio test failed.",
                runID: runID
            )
            throw error
        }
    }

    func cancelTest() async {
        switch state {
        case .idle, .cancelling:
            return
        case .preparing(let runID), .recording(let runID, _):
            state = .cancelling(runID)
            await audioCaptureService.cancelCapture(runID: runID)
            guard state == .cancelling(runID) else { return }
            state = .idle
        case .finishing(let runID, let settings, _):
            state = .finishing(runID, settings, cancelled: true)
            let operation = finishingOperation.flatMap { current in
                current.runID == runID ? current : nil
            }
            operation?.task.cancel()
            await audioCaptureService.cancelCapture(runID: runID)
            if let operation {
                _ = await operation.task.result
                clearFinishingOperation(operation)
            }
            if case .finishing(let currentRunID, _, _) = state,
               currentRunID == runID {
                state = .idle
            }
        }
    }

    func shutdown() async {
        switch lifecycle {
        case .accepting:
            lifecycle = .shuttingDown
        case .shuttingDown:
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
            return
        case .terminated:
            return
        }

        await cancelTest()
        await audioCaptureService.shutdown()
        await cleanupOwner.drain()
        diagnosticQueueSealed = true
        let pendingDiagnosticTask = diagnosticTailTask
        diagnosticTailTask = nil
        await pendingDiagnosticTask?.value
        lifecycle = .terminated
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private static func removeManagedTemporaryAudio(
        _ capturedAudio: CapturedAudio,
        runID: UUID,
        cleanupOwner: ManagedTemporaryAudioCleanupOwner
    ) async {
        guard await cleanupOwner.transfer(capturedAudio, runID: runID) else { return }
        await cleanupOwner.drain(runID: runID)
    }

    private func enqueueDiagnostic(
        level: DiagnosticLevel,
        event: String,
        message: String,
        runID: UUID
    ) {
        guard !diagnosticQueueSealed, let diagnostics else { return }
        let diagnosticEvent = DiagnosticEvent(
            runID: runID,
            subsystem: .providers,
            level: level,
            event: event,
            message: message
        )
        let previousTask = diagnosticTailTask
        diagnosticTailTask = Task {
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await diagnostics.record(diagnosticEvent)
        }
    }

    private func ownsFinishingOperation(_ operation: FinishingOperation) -> Bool {
        finishingOperation?.id == operation.id
            && finishingOperation?.runID == operation.runID
    }

    private func clearFinishingOperation(_ operation: FinishingOperation) {
        guard ownsFinishingOperation(operation)
        else { return }
        finishingOperation = nil
    }

    static let diagnosticWorkflow = WorkflowDefinition(
        id: UUID(uuidString: "5E5AE5E7-3DD9-42E1-9B85-FD8DB9D4A1E2")!,
        name: "Deepgram Connection Check",
        trigger: .menuBar,
        pipeline: PipelineDeclaration(
            recognizerID: "deepgram.prerecorded",
            outputActions: []
        ),
        ui: WorkflowUIConfig(symbolName: "waveform.badge.mic", accentColorName: "cyan")
    )

}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
