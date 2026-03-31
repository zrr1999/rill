import Foundation
import VoxTypeCore
import VoxTypeRuntime

actor WorkflowAudioRunController {
    enum RunError: Error, LocalizedError, Equatable {
        case alreadyRecording
        case notRecording

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A workflow recording is already in progress."
            case .notRecording:
                return "No workflow recording is currently active."
            }
        }
    }

    private enum State: Sendable, Equatable {
        case idle
        case recording(
            runID: UUID,
            workflow: WorkflowDefinition,
            triggerEvent: WorkflowTriggerEvent
        )
    }

    private let audioCaptureService: any AudioCaptureService
    private let sessionCoordinator: SessionCoordinator
    private let diagnostics: DiagnosticsRecorder?
    private var state: State = .idle

    init(
        audioCaptureService: any AudioCaptureService,
        sessionCoordinator: SessionCoordinator,
        diagnostics: DiagnosticsRecorder? = nil
    ) {
        self.audioCaptureService = audioCaptureService
        self.sessionCoordinator = sessionCoordinator
        self.diagnostics = diagnostics
    }

    func startRun(workflow: WorkflowDefinition, binding: TriggerBinding) async throws {
        guard case .idle = state else {
            throw RunError.alreadyRecording
        }

        let runID = UUID()
        let triggerEvent = WorkflowTriggerEvent(
            binding: binding,
            workflowID: workflow.id,
            sourceID: Self.sourceID(for: binding),
            metadata: ["requestedTrigger": workflow.trigger.rawValue]
        )
        let request = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            triggerEvent: triggerEvent,
            preferredFormat: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            metadata: [
                "source": triggerEvent.sourceID,
                "binding": binding.rawValue,
            ]
        )

        try await audioCaptureService.startCapture(request)
        state = .recording(runID: runID, workflow: workflow, triggerEvent: triggerEvent)
        await recordDiagnostic(
            level: .info,
            event: "workflow.audio-recording.started",
            message: "Started recording for \(workflow.name).",
            runID: runID
        )
    }

    func finishRun() async throws {
        guard case .recording(let runID, let workflow, let triggerEvent) = state else {
            throw RunError.notRecording
        }

        state = .idle

        do {
            let capturedAudio = try await audioCaptureService.finishCapture()
            await recordDiagnostic(
                level: .info,
                event: "workflow.audio-recording.completed",
                message: "Captured audio for \(workflow.name) and handed it to the workflow runtime.",
                runID: runID
            )
            await sessionCoordinator.run(
                workflow: workflow,
                triggerEvent: triggerEvent,
                capturedAudio: capturedAudio
            )
        } catch {
            await recordDiagnostic(
                level: .error,
                event: "workflow.audio-recording.failed",
                message: error.localizedDescription,
                runID: runID
            )
            await audioCaptureService.cancelCapture()
            throw error
        }
    }

    func cancelRun() async {
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
                subsystem: .session,
                level: level,
                event: event,
                message: message
            )
        )
    }

    private static func sourceID(for binding: TriggerBinding) -> String {
        switch binding {
        case .manual:
            return "dashboard.run"
        case .menuBar:
            return "menu-bar.run"
        case .hotkey:
            return "hotkey.run"
        case .wakeWord:
            return "wake-word.run"
        }
    }
}
