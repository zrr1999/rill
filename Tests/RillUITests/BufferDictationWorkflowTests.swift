import Foundation
import RillCore
import Testing
@testable import RillUI

private actor DraftRecordingProbe {
  var starts: [(WorkflowDefinition, TriggerBinding, BufferDraftInputIntent?)] = []
  func record(_ workflow: WorkflowDefinition, _ binding: TriggerBinding, _ intent: BufferDraftInputIntent?) {
    starts.append((workflow, binding, intent))
  }
}

@MainActor struct BufferDictationWorkflowTests {
  @Test(arguments: [false, true])
  func explicitDraftRecordingFreezesIntentAndNeverIncludesExternalInsertion(editing: Bool) async throws {
    let workflow = makeBuiltinPushToTalkWorkflow()
    let probe = DraftRecordingProbe()
    let model = makeHarness(
      workflow: workflow,
      permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
      startWorkflowAudioRunAction: { await probe.record($0, $1, $2) }
    ).model
    await model.waitForInitialVoiceConfiguration()
    let intent = BufferDraftInputIntent(
      entryID: .init(bufferID: RecordBuffer.speechID, sequence: 7),
      draftID: UUID(), revision: 4, selection: .init(location: 2, length: 3), editingSessionID: UUID())
    model.dictateToBuffer(editing ? .draft(intent) : .newItem)
    await model.waitForWorkflowAudioActions()
    let start = try #require(await probe.starts.first)
    #expect(start.0.plan.output.actions.map(\.id) == [RecordActionID.store])
    #expect(start.0.metadata[WorkflowMetadataKey.livePreviewPlacement] == LivePreviewPlacement.overlay.rawValue)
    #expect(start.0.metadata[WorkflowMetadataKey.collectSpeech] == (editing ? nil : "true"))
    #expect(start.1 == .manual)
    #expect(start.2 == (editing ? intent : nil))
    #expect(model.settings.builtinPushToTalkOutputMode == .pasteIntoApp)
    #expect(workflow.plan.output.actions.map(\.id) == ["focused-application.insert"])
    await model.stopInteractiveWorkflowRunsForApplicationShutdown()
  }
}
