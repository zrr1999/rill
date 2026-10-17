import RillDomainTestSupport
import XCTest
@testable import RillCore
@testable import RillWorkflows
import XCTest

private actor WorkflowPolicyProbe {
  private var contextCaptureCount = 0
  private var recognitionCount = 0
  private var actionCount = 0

  func recordContextCapture() { contextCaptureCount += 1 }
  func recordRecognition() { recognitionCount += 1 }
  func recordAction() { actionCount += 1 }

  func snapshot() -> (context: Int, recognition: Int, action: Int) {
    (contextCaptureCount, recognitionCount, actionCount)
  }
}

private actor WorkflowPolicyOptionsProbe {
  private var count = 0
  func record() -> SpeechRecognitionRequestOptions {
    count += 1
    return .empty
  }
  func snapshot() -> Int { count }
}

private struct WorkflowPolicyContextProvider: ContextProvider {
  let probe: WorkflowPolicyProbe

  func captureContext() async -> ContextSnapshot {
    await probe.recordContextCapture()
    return .empty
  }
}

private struct WorkflowPolicyRecognizer: SpeechRecognizer {
  let id = "policy.recognizer"
  let probe: WorkflowPolicyProbe

  func recognize(_ request: RecognitionRequest) async throws -> RecognitionResult {
    await probe.recordRecognition()
    return RecognitionResult(rawText: "unused", bestText: "unused")
  }
}

private struct WorkflowPolicyAction: OutputAction {
  let id = "policy.action"
  let probe: WorkflowPolicyProbe

  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    _ = try record.requireText(for: id)
    await probe.recordAction()
    return .copiedToClipboard
  }
}

final class WorkflowExecutionPolicyTests: XCTestCase {
  func testPlannedPresetFailsClosedBeforeRuntimeComponents() {
    var workflow = makeWorkflow()
    workflow.properties.availability = .planned

    XCTAssertEqual(
      WorkflowExecutionPolicy.issue(for: workflow),
      .plannedCapabilityUnavailable
    )
    XCTAssertFalse(WorkflowExecutionPolicy.supports(workflow))
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: workflow, on: .interactiveCapture),
      .invalidConfiguration
    )
  }

  func testPolicyKeepsInteractiveAndGroupExecutionSurfacesDisjoint() {
    let interactive = makeWorkflow()
    let group = makeStrictGroupWorkflow()
    var malformedGroup = makeWorkflow()
    malformedGroup.properties.availability = .planned

    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: interactive, on: .interactiveCapture),
      .supported
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: interactive, on: .clipboardItemReplay),
      .supported
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: interactive, on: .recordCollectionEvent),
      .wrongSurface
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: group, on: .interactiveCapture),
      .wrongSurface
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: group, on: .clipboardItemReplay),
      .wrongSurface
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(for: group, on: .recordCollectionEvent),
      .supported
    )
    XCTAssertEqual(
      WorkflowExecutionPolicy.decision(
        for: malformedGroup,
        on: .recordCollectionEvent
      ),
      .invalidConfiguration
    )
  }

  func testSessionCoordinatorRequiresExplicitAuthorizedContextBeforeComponents() async {
    let probe = WorkflowPolicyProbe()
    let optionsProbe = WorkflowPolicyOptionsProbe()
    let eventBus = EventBus()
    let coordinator = makeTestSessionCoordinator(

      recognizerRegistry: SpeechRecognizerRegistry(
        recognizers: [WorkflowPolicyRecognizer(probe: probe)]
      ),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(
        actions: [WorkflowPolicyAction(probe: probe)]
      ),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      eventBus: eventBus,
      recognitionOptionsProvider: { _, _ in await optionsProbe.record() }
    )

    let result = await coordinator.runReportingOutcome(
      workflow: makeWorkflow()
    )
    let counts = await probe.snapshot()
    let optionsCount = await optionsProbe.snapshot()

    guard case .failed(let failure) = result else {
      return XCTFail("Expected missing context to fail before component resolution")
    }
    XCTAssertNotNil(failure.runID)
    XCTAssertEqual(failure.stage, .preparing)
    XCTAssertEqual(failure.code, .configuration)
    XCTAssertEqual(counts.context, 0)
    XCTAssertEqual(counts.recognition, 0)
    XCTAssertEqual(counts.action, 0)
    XCTAssertEqual(optionsCount, 0)
    let state = await coordinator.currentState()
    XCTAssertEqual(state, .idle)
  }

  private func makeWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      name: "Legacy Clipboard Automation",
      trigger: .manual,
      plan: makeTestAudioPlan(recognizerID: "policy.recognizer", actions: [OutputActionReference(id: "policy.action")]),
      ui: WorkflowUIConfig(symbolName: "bolt", accentColorName: "orange"),
      properties: .init())
  }

  private func makeStrictGroupWorkflow() -> WorkflowDefinition {
    var workflow = makeWorkflow()
    workflow.properties.automation = .init(
      rule: .init(eventKind: .recordCreated, sourceCollectionID: RecordCollection.voiceInputID, conditions: [.excludingTag(.polishGenerated)]),
      actionKind: .editRecord)
    return workflow
  }
}
