import Foundation
import VoxTypeCore
import VoxTypePlatform

public actor RecordingSessionManager {
    public enum State: Sendable, Equatable {
        case idle
        case recording(UUID)
        case transcribing(UUID)
        case delivering(UUID)
    }

    private let audioCaptureService: any AudioCaptureService
    private let hotkeyTap: HotkeyEventTap
    private let sessionCoordinator: SessionCoordinator
    private let eventBus: EventBus
    private let diagnostics: DiagnosticsRecorder?
    private let workflowProvider: @Sendable () async -> [WorkflowDefinition]

    private var state: State = .idle
    private var started = false
    private var listenerTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var activeWorkflow: WorkflowDefinition?
    private var activeTriggerEvent: WorkflowTriggerEvent?

    public init(
        audioCaptureService: any AudioCaptureService,
        hotkeyTap: HotkeyEventTap,
        sessionCoordinator: SessionCoordinator,
        eventBus: EventBus,
        diagnostics: DiagnosticsRecorder? = nil,
        workflowProvider: @escaping @Sendable () async -> [WorkflowDefinition]
    ) {
        self.audioCaptureService = audioCaptureService
        self.hotkeyTap = hotkeyTap
        self.sessionCoordinator = sessionCoordinator
        self.eventBus = eventBus
        self.diagnostics = diagnostics
        self.workflowProvider = workflowProvider
    }

    public func currentState() -> State {
        state
    }

    public func start() async {
        guard !started else { return }
        started = true

        let stream = hotkeyTap.stream()
        listenerTask = Task {
            for await event in stream {
                await self.handle(event)
            }
        }
    }

    public func beginPushToTalk() async {
        guard case .idle = state else { return }
        let availableWorkflows = await workflowProvider()
        guard let workflow = availableWorkflows.first else { return }
        guard availableWorkflows.count == 1 else {
            let conflictingNames = availableWorkflows.map(\.name).joined(separator: ", ")
            let message = "Multiple enabled workflows share the hotkey trigger: \(conflictingNames)"
            await publishFailure(runID: nil, workflow: nil, message: message)
            return
        }
        guard workflow.trigger == .hotkey else { return }

        let runID = UUID()
        let triggerEvent = WorkflowTriggerEvent(
            binding: .hotkey,
            workflowID: workflow.id,
            sourceID: "push-to-talk",
            metadata: ["gesture": "control-option-shift-space"]
        )
        let request = AudioCaptureRequest(
            runID: runID,
            workflow: workflow,
            triggerEvent: triggerEvent,
            preferredFormat: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
            metadata: ["source": "push-to-talk"]
        )

        do {
            try await audioCaptureService.startCapture(request)
            activeRunID = runID
            activeWorkflow = workflow
            activeTriggerEvent = triggerEvent
            state = .recording(runID)
            await recordDiagnostic(
                level: .info,
                event: "recording.started",
                message: "Push-to-talk recording started.",
                runID: runID
            )
        } catch {
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: error.localizedDescription
            )
            resetState()
        }
    }

    public func endPushToTalk() async {
        guard case .recording(let runID) = state, let workflow = activeWorkflow else { return }

        state = .transcribing(runID)
        await recordDiagnostic(
            level: .debug,
            event: "recording.finishing",
            message: "Push-to-talk recording is being finalized.",
            runID: runID
        )

        do {
            let capturedAudio = try await audioCaptureService.finishCapture()
            guard case .transcribing(let expectedRunID) = state, expectedRunID == runID else {
                return
            }
            state = .delivering(runID)
            await sessionCoordinator.run(
                workflow: workflow,
                triggerEvent: activeTriggerEvent,
                capturedAudio: capturedAudio
            )
            guard case .delivering(let expectedRunID) = state, expectedRunID == runID else {
                return
            }
            await recordDiagnostic(
                level: .info,
                event: "recording.completed",
                message: "Push-to-talk recording completed and was handed to the workflow runtime.",
                runID: runID
            )
            resetState()
        } catch {
            await publishFailure(
                runID: runID,
                workflow: workflow.presentation,
                message: error.localizedDescription
            )
            await audioCaptureService.cancelCapture()
            resetState()
        }
    }

    public func cancelCurrentRecording() async {
        await audioCaptureService.cancelCapture()
        resetState()
    }

    private func handle(_ event: HotkeyEventTap.Event) async {
        switch event {
        case .pushToTalkPressed:
            await beginPushToTalk()
        case .pushToTalkReleased:
            await endPushToTalk()
        case .manualPasteInterceptRequested, .clipboardPanelRequested, .customHotkey(_):
            break
        }
    }

    private func publishFailure(runID: UUID?, workflow: WorkflowPresentation?, message: String) async {
        await recordDiagnostic(
            level: .error,
            event: "recording.failure",
            message: message,
            runID: runID
        )
        await eventBus.publish(.runFailed(runID: runID, workflow: workflow, message: message))
    }

    private func recordDiagnostic(
        level: DiagnosticLevel,
        event: String,
        message: String,
        runID: UUID?
    ) async {
        guard let diagnostics else { return }
        await diagnostics.record(
            DiagnosticEvent(
                runID: runID,
                subsystem: .platform,
                level: level,
                event: event,
                message: message
            )
        )
    }

    private func resetState() {
        state = .idle
        activeRunID = nil
        activeWorkflow = nil
        activeTriggerEvent = nil
    }
}
