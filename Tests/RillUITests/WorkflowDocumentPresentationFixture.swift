import XCTest
@testable import RillCore
@testable import RillUI

@MainActor
struct WorkflowDocumentPresentationFixture {
  static let errorTail = "ERROR_DETAIL_END"
  static let errorMessage =
    "The configured process step could not be validated. Review the step kind and its required fields in this TOML file before enabling the workflow. "
    + errorTail
  let harness: AppModelTestHarness
  let workflow: WorkflowDefinition

  static func make() async -> Self {
    let workflow = makeBuiltinPushToTalkWorkflow()
    let service = makeContentFreeExplainService()
    let files = UITestWorkflowFileStore(issues: [
      .init(filename: "broken.toml", message: errorMessage),
      .init(filename: "workflows.toml", message: "The workflow configuration path is not a directory.", target: .configurationDirectory),
    ])
    let harness = makeHarness(
      workflows: [workflow], settingsStore: UITestSettingsStore(), workflowFileStore: files,
      startWorkflowAudioRunAction: { _, _, _ in
        XCTFail("A workflow preview must not start recording")
        throw CancellationError()
      },
      authorizeWorkflowRunAction: { _ in
        XCTFail("A workflow preview must not authorize an execution")
        throw CancellationError()
      },
      explainResolvedWorkflowAction: { plan in
        return service.explainResolved(plan)
      })
    await harness.model.waitForInitialVoiceConfiguration()
    harness.model.voiceSetupPresentation = .dismissed
    return Self(harness: harness, workflow: workflow)
  }

  func shutdown() async {
    await harness.model.stopSettingsReadTasksForApplicationShutdown()
    await harness.model.flushPendingPersistenceWrites()
  }
}
