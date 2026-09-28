import Foundation
import RillCore
import RillTestSupport
import Testing

@testable import RillUI

@MainActor
struct VoiceRunModelTests {
  @Test func preparationIsOfferedOnlyForMissingOrFailedResources() {
    #expect(VoiceAssistantResourceState.notInstalled.canPrepare)
    #expect(VoiceAssistantResourceState.failed("unavailable").canPrepare)
    #expect(!VoiceAssistantResourceState.ready.canPrepare)
    #expect(!VoiceAssistantResourceState.preparing(progress: nil).canPrepare)
    #expect(!VoiceAssistantResourceState.unavailable(.distributionLicenseUnverified).canPrepare)
  }

  @Test func shutdownBeforeScheduledSpeechPreparationDoesNotStartProvider() async {
    let probe = SpeechPreparationProbe()
    let app = makeHarness(prepareLocalSpeechAction: { settings, _ in
      await probe.recordPreparation(settings: settings)
      return settings.model
    }).model
    await app.waitForInitialVoiceConfiguration()
    app.prepareLocalSpeechModel()
    app.beginApplicationShutdown()
    await app.voice.waitForLocalSpeechPreparation()
    #expect(await probe.snapshot().prepareCount == 0)
    #expect(app.voice.localSpeechPreparationTaskOwner.trackedTaskCount == 0)
  }

  @Test func changingSpeechModelRejectsLateWakePreparation() async {
    let gate = WorkflowAudioStartGate()
    let oldModel = "qwen3-asr-0.6b-mlx-8bit"
    let harness = makeHarness(
      voiceResourceServices: makeVoiceResourceServicesForTesting(
        prepareWakeWordModel: { progress in
          try await gate.suspendStart()
          progress(1)
          return oldModel
        }
      ))
    let app = harness.model
    await app.waitForInitialVoiceConfiguration()
    app.prepareWakeWordModel()
    await gate.waitUntilStarted()
    #expect(app.voice.wakeWordResourceState.isPreparing)

    app.applyLocalSpeechModel("qwen3-asr-1.7b-mlx-8bit")
    #expect(app.voice.wakeWordResourceState == .notInstalled)
    await gate.succeed()
    await app.voice.waitForResourcePreparations()

    #expect(app.voice.wakeWordResourceState == .notInstalled)
    #expect(!app.voice.downloadedLocalSpeechModels.contains(oldModel))
  }

  @Test func shutdownClosesWakePreparationAdmission() async {
    var didPrepare = false
    let app = makeHarness().model
    await app.waitForInitialVoiceConfiguration()
    app.beginApplicationShutdown()
    app.voice.prepareWakeWordModel { _ in didPrepare = true }
    #expect(app.voice.wakeWordPreparationTaskOwner.trackedTaskCount == 0)
    #expect(!app.voice.wakeWordResourceState.isPreparing)
    #expect(!didPrepare)
  }

  @Test func interleavedAndLateEventsCannotOverwriteThePrimaryRun() {
    let model = makeHarness().model.voice
    let primary = RunSnapshot(
      runID: UUID(), workflowID: UUID(), workflow: .init(fallbackName: "Primary"), trigger: .hotkey)
    let assistant = RunSnapshot(
      runID: UUID(), lane: .assistant, workflowID: UUID(),
      workflow: .init(fallbackName: "Assistant"), trigger: .hotkey)
    model.begin(primary)
    model.begin(assistant)
    model.updateText("Primary text", from: .init(runID: primary.runID))
    model.updateText("Assistant text", from: .init(runID: assistant.runID, lane: .assistant))
    model.updateText("Wrong lane", from: .init(runID: primary.runID, lane: .assistant))
    #expect(model.lastCompletedText == "Primary text")
    model.finish(primary.runID)
    #expect(model.activeRunID == assistant.runID)
    #expect(model.isRunning)
    model.updateText("Late primary", from: .init(runID: primary.runID))
    #expect(model.lastCompletedText == "Primary text")
    model.updateText("Assistant text", from: .init(runID: assistant.runID, lane: .assistant))
    #expect(model.lastCompletedText == "Assistant text")
    model.finish(assistant.runID)
    #expect(!model.isRunning)
  }
  @Test func stageEventsRemainRunAndLaneScopedAndRecordingTakesPrecedence() {
    let model = makeHarness().model.voice
    let run = RunSnapshot(
      runID: UUID(), workflowID: UUID(),
      workflow: .init(fallbackName: "Speech"), trigger: .hotkey)
    model.begin(run)
    model.updateStage(.saving, from: .init(runID: run.runID))
    #expect(model.activeStage == .saving)
    model.updateStage(.delivering, from: .init(runID: run.runID, lane: .assistant))
    #expect(model.activeStage == .saving)
    model.workflowAudioRunState = .recording(workflowID: UUID())
    #expect(model.activeStage == .capturingInput)
    model.workflowAudioRunState = .idle
    model.finish(run.runID)
    model.updateStage(.delivering, from: .init(runID: run.runID))
    #expect(model.activeStage == nil)
    #expect(!model.isRunning)
  }

}
