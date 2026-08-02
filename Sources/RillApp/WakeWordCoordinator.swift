import Foundation
import RillCore
import RillPlatform
import RillProviders
import RillRuntime

/// Connects the provider-owned local wake phrase gate to either the existing
/// captured-audio controller or the same workflow's pre-recognized text entry.
/// It owns no speech model, audio engine, or HA/Spark behavior.
actor WakeWordCoordinator {
  private let source: WakeWordTriggerSource
  private let workflowSelectionBridge: WorkflowSelectionBridge
  private let audioRunController: WorkflowAudioRunController
  private let cuePlayer: RecordingInteractionCuePlayer
  private let eventBus: EventBus
  private let diagnostics: DiagnosticsRecorder
  private let runPrefilledCommand:
    @Sendable (
      WorkflowDefinition,
      WorkflowTriggerEvent,
      String
    ) async throws -> Void

  private var triggerTask: Task<Void, Never>?
  private var terminalEventTask: Task<Void, Never>?
  private var configuredWorkflowID: UUID?
  private var configuredConfiguration: WakeWordConfiguration?
  private var activeRunID: UUID?
  private var stopped = false

  init(
    source: WakeWordTriggerSource,
    workflowSelectionBridge: WorkflowSelectionBridge,
    audioRunController: WorkflowAudioRunController,
    cuePlayer: RecordingInteractionCuePlayer,
    eventBus: EventBus,
    diagnostics: DiagnosticsRecorder,
    runPrefilledCommand:
      @escaping @Sendable (
        WorkflowDefinition,
        WorkflowTriggerEvent,
        String
      ) async throws -> Void
  ) {
    self.source = source
    self.workflowSelectionBridge = workflowSelectionBridge
    self.audioRunController = audioRunController
    self.cuePlayer = cuePlayer
    self.eventBus = eventBus
    self.diagnostics = diagnostics
    self.runPrefilledCommand = runPrefilledCommand
  }

  func start() async {
    guard triggerTask == nil, terminalEventTask == nil, !stopped else { return }
    let terminalEvents = await eventBus.stream()
    terminalEventTask = Task { [weak self] in
      for await event in terminalEvents {
        guard !Task.isCancelled else { return }
        await self?.handleTerminalEvent(event)
      }
    }
    let triggers = source.stream()
    triggerTask = Task { [weak self] in
      for await event in triggers {
        guard !Task.isCancelled else { return }
        await self?.handleTrigger(event)
      }
    }
    await reconcile()
  }

  func reconcile() async {
    guard !stopped, activeRunID == nil else { return }
    let workflows = await MainActor.run {
      workflowSelectionBridge.enabledWorkflows(for: .wakeWord)
    }
    guard
      let workflow = workflows.first,
      workflows.count == 1,
      let configuration = workflow.plan.setup.wakeWord
    else {
      configuredWorkflowID = nil
      configuredConfiguration = nil
      await source.stop()
      return
    }
    if configuredWorkflowID == workflow.id,
      configuredConfiguration == configuration,
      await source.currentStatus() == .listening
    {
      return
    }

    do {
      try await source.start(
        configuration: configuration,
        workflow: workflow
      )
      configuredWorkflowID = workflow.id
      configuredConfiguration = configuration
    } catch {
      await diagnostics.record(
        DiagnosticEvent(
          subsystem: .providers,
          level: .warning,
          event: "wake-word.start-failed",
          message: "Local wake-word listening could not start.",
          metadata: ["reason": "request-failed"]
        )
      )
    }
  }

  func shutdown() async {
    guard !stopped else { return }
    stopped = true
    triggerTask?.cancel()
    terminalEventTask?.cancel()
    triggerTask = nil
    terminalEventTask = nil
    await source.shutdown()
  }

  private func handleTrigger(_ event: WorkflowTriggerEvent) async {
    guard activeRunID == nil,
      event.binding == .wakeWord,
      let workflowID = event.workflowID
    else {
      await source.resume(from: .busy)
      return
    }
    let workflow = await MainActor.run {
      workflowSelectionBridge.enabledWorkflows(for: .wakeWord)
        .first(where: { $0.id == workflowID })
    }
    guard let workflow else {
      await source.resume(from: .busy)
      await reconcile()
      return
    }

    activeRunID = event.id
    await diagnostics.record(
      DiagnosticEvent(
        runID: event.id,
        subsystem: .providers,
        level: .info,
        event: "wake-word.detected",
        message: "A configured local wake phrase was detected."
      )
    )
    await MainActor.run {
      cuePlayer.play(.started)
    }
    do {
      if let command = await source.claimPrefilledCommand(for: event.id) {
        try await runPrefilledCommand(workflow, event, command)
      } else {
        try await audioRunController.startRun(
          workflow: workflow,
          binding: .wakeWord,
          triggerEvent: event
        )
      }
    } catch {
      activeRunID = nil
      await source.resume(from: .busy)
      await diagnostics.record(
        DiagnosticEvent(
          runID: event.id,
          subsystem: .session,
          level: .warning,
          event: "wake-word.run-rejected",
          message: "A wake-word workflow could not start.",
          metadata: ["reason": "request-failed"]
        )
      )
      await reconcile()
    }
  }

  private func handleTerminalEvent(_ event: RillEvent) async {
    let terminalRunID: UUID?
    switch event {
    case .runCompleted(let summary):
      terminalRunID = summary.runID
    case .runCancelled(let summary):
      terminalRunID = summary.runID
    case .runFailed(let runID, _, _):
      terminalRunID = runID
    default:
      return
    }
    guard let terminalRunID, terminalRunID == activeRunID else { return }
    activeRunID = nil
    await source.resume(from: .busy)
    await reconcile()
  }
}
