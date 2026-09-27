import RillCore

/// Phase detail for the in-progress voice run shown on the Stream page.
enum StreamActivityPhase: Sendable, Equatable {
    case preparing
    case recording
    case transcribing
    case running
    case resolving, transforming, saving, delivering
}

/// Pure presentation policy for the Stream page in-progress status card.
///
/// The menu bar derives the same "run active" semantics from
/// `AppModel.isRunning` (see `MenuBarOperationPanelState.statusTitle`); this
/// type refines that signal with the observable per-phase state so the Stream
/// page matches the menu bar and the LiveSubtitle overlay (docs/ui-direction.md
/// "状态永远可见": ready, failure, and in-progress read the same on all three
/// surfaces).
struct StreamActivityPresentation: Sendable, Equatable {
    let phase: StreamActivityPhase
    let title: String
    let detail: String
    let symbol: RillSystemSymbol

    static func make(
        isRunning: Bool,
        workflowAudioRunState: WorkflowAudioRunState,
        isAudioProcessingQueueVisible: Bool,
        language: AppLanguage,
        activeStage: WorkflowRunStage? = nil
    ) -> StreamActivityPresentation? {
        switch workflowAudioRunState {
        case .idle, .transcribing:
            if isRunning || isAudioProcessingQueueVisible,
               let activeStage, let phase = processingPhase(activeStage) {
                return .init(phase: phase, title: L10n.runStageTitle(activeStage, language: language),
                    detail: L10n.string(.menuStatusRunningDetail, language: language), symbol: .hourglass)
            }
        case .preparing, .recording: break
        }
        switch workflowAudioRunState {
        case .preparing:
            return StreamActivityPresentation(
                phase: .preparing,
                title: L10n.text(.workflowPreparingAudio, language: language),
                detail: L10n.string(.menuStatusRunningDetail, language: language),
                symbol: .hourglass
            )
        case .recording:
            return StreamActivityPresentation(
                phase: .recording,
                title: L10n.text(.streamActivityRecording, language: language),
                detail: L10n.string(.menuStatusRunningDetail, language: language),
                symbol: .micFill
            )
        case .transcribing:
            return StreamActivityPresentation(
                phase: .transcribing,
                title: L10n.text(.workflowTranscribing, language: language),
                detail: L10n.string(.menuStatusRunningDetail, language: language),
                symbol: .waveform
            )
        case .idle:
            break
        }

        if isRunning {
            return StreamActivityPresentation(
                phase: .running,
                title: L10n.string(.menuStatusRunning, language: language),
                detail: L10n.string(.menuStatusRunningDetail, language: language),
                symbol: .waveformCircleFill
            )
        }

        // Captured audio can still be in the processing queue after the
        // tracked run projection has ended (see
        // `AppModel.hasActiveOrQueuedVoiceRun`).
        if isAudioProcessingQueueVisible {
            return StreamActivityPresentation(
                phase: .transcribing,
                title: L10n.text(.workflowTranscribing, language: language),
                detail: L10n.string(.menuStatusRunningDetail, language: language),
                symbol: .waveform
            )
        }

        return nil
    }
    private static func processingPhase(_ stage: WorkflowRunStage) -> StreamActivityPhase? {
        switch stage {
        case .recognizing: .transcribing
        case .resolving: .resolving
        case .transforming: .transforming
        case .saving: .saving
        case .delivering: .delivering
        case .preparing, .capturingInput, .completed, .failed: nil
        }
    }

}
