import XCTest

@testable import RillCore
@testable import RillRuntime

final class RecordReuseCoordinatorTests: XCTestCase {
  func testRepeatedHistoryReuseUsesOutputAndDurableReceiptPathWithoutMemberships() async throws {
    let fixture = try await makeFixture()
    for _ in 0..<2 {
      let result = await fixture.coordinator.reuseRecord(fixture.subject, to: fixture.target)
      XCTAssertEqual(result, .delivered)
    }
    let outputs = await fixture.probe.values
    XCTAssertEqual(outputs, ["history", "history"])
    let record = try await fixture.store.record(id: fixture.subject.recordID)
    XCTAssertEqual(record?.activity.useCount, 2)
    XCTAssertTrue(record?.memberships.isEmpty == true)
    let receipts = try await fixture.receipts.receipts(matching: .all)
    XCTAssertEqual(receipts.count, 2)
    XCTAssertTrue(
      receipts.allSatisfy {
        $0.termination == .completed && $0.actionDetails.map(\.result) == [.injected]
      })
  }

  func testTargetChangePreventsOutput() async throws {
    let fixture = try await makeFixture()
    let other = try XCTUnwrap(
      FocusedApplicationTargetIdentity(processIdentifier: 99, bundleIdentifier: "com.example.other")
    )
    let result = await fixture.coordinator.reuseRecord(fixture.subject, to: other)
    XCTAssertEqual(result, .targetUnavailable)
    let outputs = await fixture.probe.values
    XCTAssertTrue(outputs.isEmpty)
    let record = try await fixture.store.record(id: fixture.subject.recordID)
    XCTAssertEqual(record?.activity.useCount, 0)
  }

  func testCommittedOutputFailureDoesNotRepeatSideEffectAndKeepsReceipt() async throws {
    let fixture = try await makeFixture(failAfterOutput: true)
    let result = await fixture.coordinator.reuseRecord(fixture.subject, to: fixture.target)
    XCTAssertEqual(result, .outputCommittedWithIssue)
    await fixture.coordinator.shutdownRecordDeliverySettlements()
    let outputs = await fixture.probe.values
    XCTAssertEqual(outputs, ["history"])
    let receipts = try await fixture.receipts.receipts(matching: .all)
    XCTAssertEqual(receipts.first?.termination, .partiallyCompleted(code: .processing))
    let record = try await fixture.store.record(id: fixture.subject.recordID)
    XCTAssertEqual(record?.activity.useCount, 1)
  }

  private func makeFixture(failAfterOutput: Bool = false) async throws -> Fixture {
    let store = RecordStore()
    let record = try await store.ingest(
      .init(payload: .text("history"), provenance: .init(source: .init(kind: .systemClipboard))),
      into: [])
    let target = try XCTUnwrap(
      FocusedApplicationTargetIdentity(
        processIdentifier: 42, bundleIdentifier: "com.example.editor"))
    let context = ContextSnapshot(
      focus: FocusSnapshot(
        applicationName: "Editor", bundleIdentifier: target.bundleIdentifier,
        processIdentifier: 42, focusedRole: "AXTextArea", selectedText: "", secureInput: false),
      clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 0))
    let bus = EventBus()
    let receipts = InMemoryWorkflowRunReceiptRepository()
    let probe = ReuseOutputProbe()
    let coordinator = SessionCoordinator(
      contextProvider: ReuseContextProvider(context: context), privacyContextProvider: { context },
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [
        ReuseOutputAction(probe: probe, failAfterOutput: failAfterOutput)
      ]),
      candidateResolver: CandidateResolver(eventBus: bus), recordStore: store, eventBus: bus,
      runReceiptRecorder: WorkflowRunReceiptRecorder(repository: receipts, eventBus: bus))
    return Fixture(
      store: store, coordinator: coordinator,
      subject: .init(recordID: record.id, metadataRevision: record.metadata.revision),
      target: target, probe: probe, receipts: receipts)
  }
  private struct Fixture {
    let store: RecordStore
    let coordinator: SessionCoordinator
    let subject: RecordReuseSubject
    let target: FocusedApplicationTargetIdentity
    let probe: ReuseOutputProbe
    let receipts: InMemoryWorkflowRunReceiptRepository
  }
}

private actor ReuseOutputProbe {
  var values: [String] = []
  func record(_ text: String) { values.append(text) }
}
private struct ReuseContextProvider: ContextProvider {
  let context: ContextSnapshot
  func captureContext() async -> ContextSnapshot { context }
}
private struct ReuseOutputAction: OutputAction {
  let id = RecordActionID.focusedApplicationInsert
  let probe: ReuseOutputProbe
  let failAfterOutput: Bool
  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    await probe.record(text)
    if failAfterOutput { throw CommittedOutputFailure.clipboardRestorationFailedAfterInjection }
    return .injected
  }
}
