import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
final class WebhookReleaseGateTests: XCTestCase {
  func testLegacyWebhookWorkflowIsRejectedBeforeAppModelExecution() {
    let workflow = WorkflowDefinition(
      name: "Legacy Webhook",
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "ui.test.recognizer")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]),
        output: WorkflowOutputPhase(
          actions: [
            OutputActionReference(
              id: ExternalOutputActionID.webhookPost,
              configuration: .init(webhookURL: "https://example.com/private-hook")
            )
          ], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "network.slash", accentColorName: "orange")
    )
    let harness = makeHarness(workflow: workflow)
    harness.model.applyLanguage(.english)

    XCTAssertFalse(harness.model.canTriggerWorkflow(workflow))
    harness.model.runWorkflow(workflow)

    XCTAssertFalse(harness.model.voice.isRunning)
    XCTAssertEqual(
      harness.model.lastFailure,
      "This workflow cannot run because no production output action is registered for \(ExternalOutputActionID.webhookPost)."
    )
  }

  func testShortcutsAndMarkdownActionsRemainSupported() {
    for actionID in [
      ExternalOutputActionID.shortcutsRun,
      ExternalOutputActionID.markdownAppend,
    ] {
      let workflow = WorkflowDefinition(
        name: "Supported External Output",
        plan: WorkflowPlan(
          setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "ui.test.recognizer")),
          process: WorkflowProcessPhase(steps: [
            WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
            WorkflowProcessStep(kind: .applyVocabulary),
          ]), output: WorkflowOutputPhase(actions: [OutputActionReference(id: actionID)], deliveryPolicy: .init(strategy: .immediate))),
        ui: WorkflowUIConfig(symbolName: "square.and.arrow.up", accentColorName: "blue")
      )
      let harness = makeHarness(workflow: workflow)

      XCTAssertTrue(harness.model.canTriggerWorkflow(workflow), actionID)
    }
  }

  func testPersistedLegacyWebhookConfigurationIsPreservedButNotEnabledForExecution() async throws {
    let workflow = WorkflowDefinition(
      name: "Persisted Legacy Webhook",
      trigger: .manual,
      plan: WorkflowPlan(
        setup: WorkflowSetupPhase(speechRoute: WorkflowSpeechRoute(recognizerID: "ui.test.recognizer")),
        process: WorkflowProcessPhase(steps: [
          WorkflowProcessStep(kind: .recognizeSpeech), WorkflowProcessStep(kind: .resolveUncertainty, uncertaintyPolicy: .init()),
          WorkflowProcessStep(kind: .applyVocabulary),
        ]),
        output: WorkflowOutputPhase(
          actions: [
            OutputActionReference(
              id: ExternalOutputActionID.webhookPost,
              configuration: .init(webhookURL: "https://example.com/preserved-hook", webhookHeadersJSON: #"{"X-Project":"preserved"}"#)
            )
          ], deliveryPolicy: .init(strategy: .immediate))),
      ui: WorkflowUIConfig(symbolName: "network.slash", accentColorName: "orange"),
      properties: .init())
    let encoded = try XCTUnwrap(
      String(data: JSONEncoder().encode([workflow]), encoding: .utf8)
    )
    let settingsStore = UITestSettingsStore(storage: [.customWorkflows: encoded])
    let harness = makeHarness(settingsStore: settingsStore)

    await harness.model.waitForInitialVoiceConfiguration()

    XCTAssertTrue(harness.model.workflowLibrary.customWorkflows.isEmpty)
    XCTAssertFalse(harness.model.enabledWorkflows(for: .manual).contains { $0.id == workflow.id })

    let storage = await settingsStore.activitySnapshot()
    XCTAssertEqual(storage.storage[.customWorkflows], encoded)
    XCTAssertNil(storage.setCounts[.customWorkflows])
    XCTAssertNil(storage.removeCounts[.customWorkflows])
  }
}
