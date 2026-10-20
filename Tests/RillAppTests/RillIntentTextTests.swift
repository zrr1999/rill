@testable import RillApp
@testable import RillUI
import RillCore
import RillWorkflows
import RillDomainTestSupport
import RillTestSupport
import XCTest

@MainActor
final class RillIntentTextTests: XCTestCase {
  func testLastTranscriptionRejectsBlankText() {
    XCTAssertNil(RillIntentText.lastTranscription(in: nil))
    XCTAssertNil(RillIntentText.lastTranscription(in: " \n"))
    XCTAssertEqual(RillIntentText.lastTranscription(in: " hello "), "hello")
  }

  func testWorkflowIntentRejectsBusyAndLoadingAdmission() async throws {
    let workflow = WorkflowDefinition(
      name: "Manual test",
      plan: .init(setup: .init(), process: .init(), output: .init(actions: [])),
      ui: .init(symbolName: "text.bubble", accentColorName: "blue"))
    let model = makeModel(workflows: [workflow])
    RillIntentBridge.model = model
    defer { RillIntentBridge.model = nil }
    let intent = RunWorkflowIntent()
    intent.workflow = .init(id: workflow.id, name: workflow.name)
    XCTAssertEqual(model.enabledWorkflows(for: .manual).map(\.id), [workflow.id])

    for loading in [false, true] {
      model.settings.isLoading = loading
      model.voice.isRunning = !loading
      do {
        _ = try await intent.perform()
        XCTFail("An unaccepted workflow must fail the shortcut.")
      } catch {
        XCTAssertTrue(error is RillIntentFailure)
      }
      XCTAssertNil(model.voice.pendingInteractiveWorkflowTask)
    }
    model.settings.isLoading = false
    model.voice.isRunning = false
    await model.stopInteractiveWorkflowRunsForApplicationShutdown()
    await model.recordWorkspace.shutdown()
  }

  func testCopyIntentRejectsMissingTextWithoutChangingClipboardAndReturnsCopiedText() async throws {
    var copies: [String] = []
    let model = makeModel(workflows: [], copy: { copies.append($0) })
    RillIntentBridge.model = model
    defer { RillIntentBridge.model = nil }
    let intent = CopyLastTranscriptionIntent()
    do {
      _ = try await intent.perform()
      XCTFail("Missing transcription must fail the shortcut.")
    } catch {
      XCTAssertTrue(error is RillIntentFailure)
    }
    XCTAssertTrue(copies.isEmpty)
    model.voice.lastCompletedText = " hello "
    let result = try await intent.perform()
    XCTAssertEqual(result.value, "hello")
    XCTAssertEqual(copies, ["hello"])
    await model.recordWorkspace.shutdown()
  }

  private func makeModel(
    workflows: [WorkflowDefinition], copy: @escaping @MainActor (String) -> Void = { _ in }
  ) -> AppModel {
    let eventBus = EventBus()
    let resolver = CandidateResolver(eventBus: eventBus)
    let actions = OutputActionRegistry(actions: [])
    return makeAppModelForTesting(
      workflows: workflows, eventBus: eventBus,
      sessionCoordinator: makeTestSessionCoordinator(
        recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
        transformerRegistry: TextTransformerRegistry(transformers: []),
        actionRegistry: actions, candidateResolver: resolver, eventBus: eventBus),
      outputActionRegistry: actions, candidateResolver: resolver,
      loadsPersistentSettingsOnInitialization: false, historyRetentionMaintenanceInterval: nil,
      writeClipboardTextAction: copy, deliverNextRecordAction: {},
      permissionSnapshot: .init(accessibility: .granted, microphone: .granted),
      refreshPermissionsAction: {}, requestAccessibilityAction: {}, requestMicrophoneAction: {},
      openAccessibilitySettingsAction: {}, openMicrophoneSettingsAction: {},
      requestGlobalInputAction: {}, retryGlobalInputAction: {}, workflowLibraryChangedAction: {})
  }
}
