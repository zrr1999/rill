import Foundation
import RillCore
import Testing

@testable import RillUI

@MainActor
struct VoiceRunModelTests {
  @Test func interleavedAndLateEventsCannotOverwriteThePrimaryRun() {
    let model = VoiceRunModel()
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
    let model = VoiceRunModel()
    let run = RunSnapshot(runID: UUID(), workflowID: UUID(),
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
