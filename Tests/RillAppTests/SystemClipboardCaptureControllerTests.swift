import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime

private struct RecordCaptureTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private enum RecordCaptureTestError: Error {
  case changeCountMismatch
}

private actor SelectedRecordDeliveryProbe {
  private var values: [String] = []

  func record(_ value: String) {
    values.append(value)
  }

  func snapshot() -> [String] {
    values
  }
}

private struct SelectedRecordInsertAction: OutputAction {
  let id = RecordActionID.focusedApplicationInsert
  let probe: SelectedRecordDeliveryProbe
  let pasteboard: RecordCaptureTestPasteboard?

  init(
    probe: SelectedRecordDeliveryProbe,
    pasteboard: RecordCaptureTestPasteboard? = nil
  ) {
    self.probe = probe
    self.pasteboard = pasteboard
  }

  func execute(text: String, context: ActionContext) async throws -> ActionResult {
    if let pasteboard {
      let descriptor = await pasteboard.currentClipboardDescriptor()
      let transaction = try await pasteboard.beginTemporaryClipboardWrite(
        SystemClipboardSnapshot(plainText: text, changeCount: 0),
        ifChangeCountIs: descriptor.changeCount
      )
      _ = await pasteboard.restoreTemporaryClipboardWrite(
        transaction,
        ifChangeCountIs: transaction.temporaryChangeCount
      )
    }
    await probe.record(text)
    return .injected
  }
}

@MainActor
private final class RecordCaptureTestPasteboard: SystemClipboardAccess {
  private var snapshot: SystemClipboardSnapshot
  private var ownedChangeCounts: Set<Int> = []
  private var preservedSnapshots: [Int: SystemClipboardSnapshot] = [:]

  init(snapshot: SystemClipboardSnapshot) {
    self.snapshot = snapshot
  }

  func replaceExternally(with snapshot: SystemClipboardSnapshot) {
    self.snapshot = snapshot
  }

  func currentSnapshot() -> SystemClipboardSnapshot {
    snapshot
  }

  func currentClipboardDescriptor() async -> SystemClipboardDescriptor {
    SystemClipboardDescriptor(snapshot: snapshot)
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot? {
    snapshot.changeCount == expected ? snapshot : nil
  }

  func beginTemporaryClipboardWrite(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async throws -> SystemClipboardPort.TemporaryWriteTransaction {
    guard self.snapshot.changeCount == expected else {
      throw RecordCaptureTestError.changeCountMismatch
    }
    let preservedSnapshot = self.snapshot
    self.snapshot = snapshot.withChangeCount(expected + 1)
    preservedSnapshots[expected + 1] = preservedSnapshot
    ownedChangeCounts.insert(expected + 1)
    return .init(preservedContents: .init(items: []), temporaryChangeCount: expected + 1)
  }

  func writeClipboardSnapshot(
    _ snapshot: SystemClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async -> Int? {
    guard self.snapshot.changeCount == expected else { return nil }
    self.snapshot = snapshot.withChangeCount(expected + 1)
    ownedChangeCounts.insert(expected + 1)
    return expected + 1
  }

  func restoreTemporaryClipboardWrite(
    _ transaction: SystemClipboardPort.TemporaryWriteTransaction,
    ifChangeCountIs expected: Int
  ) async -> SystemClipboardPort.TemporaryRestoreOutcome {
    guard snapshot.changeCount == expected else { return .skippedChangeCount }
    guard let preservedSnapshot = preservedSnapshots.removeValue(
      forKey: transaction.temporaryChangeCount
    ) else {
      return .writeFailed(retryChangeCount: expected)
    }
    snapshot = preservedSnapshot.withChangeCount(expected + 1)
    ownedChangeCounts.insert(expected + 1)
    return .restored
  }

  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool {
    ownedChangeCounts.contains(changeCount)
  }
}

private extension SystemClipboardSnapshot {
  func withChangeCount(_ changeCount: Int) -> SystemClipboardSnapshot {
    SystemClipboardSnapshot(
      plainText: plainText,
      imagePNGData: imagePNGData,
      fileURLs: fileURLs,
      changeCount: changeCount,
      captureTags: captureTags
    )
  }
}

final class SystemClipboardCaptureControllerTests: XCTestCase {
  func testSelectedManualRecordIsDeliveredThroughExactFocusedApplicationPath() async throws {
    let store = RecordStore()
    let list = try await store.createCollection(name: "Reusable", preset: .list)
    let selected = try await store.ingest(
      RecordDraft(
        payload: .text("selected record"),
        provenance: RecordProvenance(source: .init(kind: .user))
      ),
      into: [list.id]
    )
    let membership = try XCTUnwrap(selected.memberships.first)
    let subject = RecordDeliverySubject(
      recordID: selected.id,
      membershipID: membership.id,
      membershipRevision: membership.revision,
      collectionID: list.id,
      payloadKind: .text
    )
    let focus = FocusSnapshot(
      applicationName: "Editor",
      bundleIdentifier: "com.example.Editor",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let target = try XCTUnwrap(FocusedApplicationTargetIdentity(focus: focus))
    let context = ContextSnapshot(
      focus: focus,
      clipboard: SystemClipboardSnapshot(plainText: "", changeCount: 1)
    )
    let eventBus = EventBus()
    let probe = SelectedRecordDeliveryProbe()
    let coordinator = SessionCoordinator(
      contextProvider: RecordCaptureTestContextProvider(),
      privacyContextProvider: { context },
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [
        SelectedRecordInsertAction(probe: probe),
      ]),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      recordStore: store,
      eventBus: eventBus
    )
    let pasteboard = await MainActor.run {
      RecordCaptureTestPasteboard(
        snapshot: SystemClipboardSnapshot(plainText: "existing", changeCount: 1)
      )
    }
    let controller = SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(),
      pasteboard: pasteboard,
      contextProvider: RecordCaptureTestContextProvider(),
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: { focus },
      accessibilityChecker: { true }
    )

    await controller.deliverSelectedRecord(subject, to: target)

    let deliveredValues = await probe.snapshot()
    let storedProjection = try await store.record(id: selected.id)
    let stored = try XCTUnwrap(storedProjection)
    XCTAssertEqual(deliveredValues, ["selected record"])
    XCTAssertEqual(stored.memberships.first?.state, .active)
    XCTAssertEqual(stored.activity.useCount, 1)
  }

  func testSelectedDeliverySettlesMirroredPreviewBeforeNestedClipboardInjection() async throws {
    let store = RecordStore()
    let list = try await store.createCollection(name: "Reusable", preset: .list)
    let selected = try await store.ingest(
      RecordDraft(
        payload: .text("selected record"),
        provenance: RecordProvenance(source: .init(kind: .user))
      ),
      into: [list.id]
    )
    let membership = try XCTUnwrap(selected.memberships.first)
    let subject = RecordDeliverySubject(
      recordID: selected.id,
      membershipID: membership.id,
      membershipRevision: membership.revision,
      collectionID: list.id,
      payloadKind: .text
    )
    let focus = FocusSnapshot(
      applicationName: "Editor",
      bundleIdentifier: "com.example.Editor",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let target = try XCTUnwrap(FocusedApplicationTargetIdentity(focus: focus))
    let context = ContextSnapshot(
      focus: focus,
      clipboard: SystemClipboardSnapshot(plainText: "existing", changeCount: 1)
    )
    let eventBus = EventBus()
    let probe = SelectedRecordDeliveryProbe()
    let pasteboard = await MainActor.run {
      RecordCaptureTestPasteboard(
        snapshot: SystemClipboardSnapshot(plainText: "existing", changeCount: 1)
      )
    }
    let coordinator = SessionCoordinator(
      contextProvider: RecordCaptureTestContextProvider(),
      privacyContextProvider: { context },
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [
        SelectedRecordInsertAction(probe: probe, pasteboard: pasteboard),
      ]),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      recordStore: store,
      eventBus: eventBus
    )
    let controller = SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(),
      pasteboard: pasteboard,
      contextProvider: RecordCaptureTestContextProvider(),
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: { focus },
      accessibilityChecker: { true }
    )

    await controller.start(initialClipboardCaptureEnabled: true)
    await controller.testingHandleRouteSnapshot(
      RecordRouteProjection(
        collection: list,
        count: 1,
        previewText: "selected record",
        previewSubject: subject,
        previewPayload: .text("selected record")
      ),
      routeContext: RecordRouteContext(
        applicationName: "Editor",
        bundleIdentifier: "com.example.Editor"
      )
    )

    await controller.deliverSelectedRecord(subject, to: target)

    let finalSnapshot = await MainActor.run { pasteboard.currentSnapshot() }
    XCTAssertEqual(finalSnapshot.plainText, "existing")
    await controller.stop()
  }

  func testExternalClipboardChangeCreatesOneRecordInEveryMatchedCollection() async throws {
    let store = RecordStore()
    let secondCollection = try await store.createCollection(name: "Research")
    try await store.replaceCaptureRules([
      CaptureRouteRule(
        matcher: .init(sourceKinds: [.systemClipboard]),
        destinationCollectionIDs: [RecordCollection.inboxID, secondCollection.id]
      )
    ])

    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: RecordCaptureTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      recordStore: store,
      eventBus: eventBus
    )
    let initial = SystemClipboardSnapshot(plainText: "initial", changeCount: 1)
    let pasteboard = await MainActor.run { RecordCaptureTestPasteboard(snapshot: initial) }
    let focus = FocusSnapshot(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes",
      processIdentifier: 42,
      focusedRole: "AXTextArea",
      selectedText: "",
      secureInput: false
    )
    let controller = SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(),
      pasteboard: pasteboard,
      contextProvider: RecordCaptureTestContextProvider(),
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: { focus },
      accessibilityChecker: { false }
    )

    await controller.start(initialClipboardCaptureEnabled: true)
    await MainActor.run {
      pasteboard.replaceExternally(
        with: SystemClipboardSnapshot(plainText: "captured once", changeCount: 2)
      )
    }
    await controller.testingCaptureExternalClipboardIfNeeded()

    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.records.count, 1)
    XCTAssertEqual(snapshot.records.first?.record.payload, .text("captured once"))
    XCTAssertEqual(Set(snapshot.records.first?.memberships.map(\.collectionID) ?? []), [
      RecordCollection.inboxID,
      secondCollection.id,
    ])
    await controller.stop()
  }

  func testPausedCaptureDoesNotReadExternalPayload() async throws {
    let store = RecordStore()
    let eventBus = EventBus()
    let coordinator = SessionCoordinator(
      contextProvider: RecordCaptureTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      recordStore: store,
      eventBus: eventBus
    )
    let pasteboard = await MainActor.run {
      RecordCaptureTestPasteboard(
        snapshot: SystemClipboardSnapshot(plainText: "private", changeCount: 1)
      )
    }
    let controller = SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(),
      pasteboard: pasteboard,
      contextProvider: RecordCaptureTestContextProvider(),
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      accessibilityChecker: { false }
    )

    await controller.start(initialClipboardCaptureEnabled: false)
    await controller.testingCaptureExternalClipboardIfNeeded()

    let storeSnapshot = try await store.snapshot()
    let controlSnapshot = await controller.testingCaptureControlSnapshot()
    XCTAssertTrue(storeSnapshot.records.isEmpty)
    XCTAssertTrue(controlSnapshot.state.isPaused)
    await controller.stop()
  }
}
