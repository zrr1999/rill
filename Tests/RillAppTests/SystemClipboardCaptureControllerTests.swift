import AppKit
import Testing
import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillPersistence
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
  var failedReadsRemaining = 0
  var advertisesTextBeforeData = false
  private(set) var payloadReadCount = 0
  private(set) var descriptorReadCount = 0

  init(snapshot: SystemClipboardSnapshot) {
    self.snapshot = snapshot
  }

  func replaceExternally(with snapshot: SystemClipboardSnapshot) {
    self.snapshot = snapshot
  }

  func currentSnapshot() -> SystemClipboardSnapshot {
    snapshot
  }

  func currentClipboardChangeCount() async -> Int {
    snapshot.changeCount
  }

  func currentClipboardDescriptor() async -> SystemClipboardDescriptor {
    descriptorReadCount += 1
    var descriptor = SystemClipboardDescriptor(snapshot: snapshot)
    if advertisesTextBeforeData { descriptor.hasPlainText = true }
    return descriptor
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> SystemClipboardSnapshot? {
    payloadReadCount += 1
    if failedReadsRemaining > 0 {
      failedReadsRemaining -= 1
      return nil
    }
    return snapshot.changeCount == expected ? snapshot : nil
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

@MainActor
struct ClipboardCaptureLatencyTests {
  @Test(arguments: [false, true])
  func retriesAnUnfinishedCopyWithoutAnotherChangeCount(advertisesText: Bool) async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.advertisesTextBeforeData = advertisesText
    pasteboard.replaceExternally(with: .init(plainText: "", changeCount: 2))
    let start = ContinuousClock.now
    for offset in [0, 50, 100, 150, 200] {
      await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(offset))
    }
    #expect(try await store.snapshot().records.isEmpty)

    pasteboard.replaceExternally(with: .init(plainText: "ready", changeCount: 2))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(450))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(500))
    #expect(try await store.snapshot().records.map(\.record.payload) == [.text("ready")])
    await controller.stop()
  }

  @Test
  func retriesATransientReadFailureWithoutDuplicatingHistory() async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.failedReadsRemaining = 2
    pasteboard.replaceExternally(with: .init(plainText: "retry", changeCount: 2))
    let start = ContinuousClock.now
    for index in 0..<4 {
      await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(50 * index))
    }
    #expect(try await store.snapshot().records.map(\.record.payload) == [.text("retry")])
    #expect(pasteboard.payloadReadCount == 3)
    await controller.stop()
  }

  @Test
  func boundsFailedReadsAndStillCapturesTheNextCopy() async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.failedReadsRemaining = 100
    pasteboard.replaceExternally(with: .init(plainText: "unavailable", changeCount: 2))
    let start = ContinuousClock.now
    for index in 0..<20 {
      await controller.testingPollExternalClipboardIfNeeded(at: start + .seconds(index * 3))
    }
    #expect(try await store.snapshot().records.isEmpty)
    #expect(pasteboard.payloadReadCount == 9)

    pasteboard.failedReadsRemaining = 0
    pasteboard.replaceExternally(with: .init(plainText: "next copy", changeCount: 3))
    await controller.testingPollExternalClipboardIfNeeded()
    #expect(try await store.snapshot().records.map(\.record.payload) == [.text("next copy")])
    await controller.stop()
  }

  @Test
  func leavesTheClipboardUnchangedWhileASlowCopyIsPending() async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.failedReadsRemaining = 7
    pasteboard.replaceExternally(with: .init(plainText: "slow copy", changeCount: 2))
    let start = ContinuousClock.now
    for offset in [0, 50, 100, 150, 200, 450, 1_200] {
      await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(offset))
    }
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(1_950))
    #expect(pasteboard.currentSnapshot().plainText == "slow copy")
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(2_200))
    #expect(try await store.snapshot().records.map(\.record.payload) == [.text("slow copy")])
    #expect(pasteboard.currentSnapshot().plainText == "slow copy")
    #expect(pasteboard.currentSnapshot().changeCount == 2)
    await controller.stop()
  }

  @Test
  func retryStillHonorsClipboardPrivacy() async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.failedReadsRemaining = 1
    pasteboard.replaceExternally(with: .init(plainText: "pending", changeCount: 2))
    let start = ContinuousClock.now
    await controller.testingPollExternalClipboardIfNeeded(at: start)
    pasteboard.replaceExternally(
      with: .init(plainText: "private", changeCount: 2, protections: [.concealed]))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(50))
    #expect(try await store.snapshot().records.isEmpty)
    #expect(pasteboard.payloadReadCount == 1)
    await controller.stop()
  }

  @Test
  func idlePollingAvoidsRepeatedDescriptorsAndPayloadReads() async throws {
    let (controller, pasteboard, _) = await makeHarness()
    await controller.testingPollExternalClipboardIfNeeded()
    let initialDescriptorReads = pasteboard.descriptorReadCount
    for _ in 0..<20 { await controller.testingPollExternalClipboardIfNeeded() }
    #expect(pasteboard.descriptorReadCount == initialDescriptorReads)
    #expect(pasteboard.payloadReadCount == 0)
    await controller.stop()
  }

  @Test(arguments: [false, true])
  func changingCaptureControlsDiscardsRetriesForTheOldBaseline(ignoreNext: Bool) async throws {
    let (controller, pasteboard, store) = await makeHarness()
    pasteboard.failedReadsRemaining = 1
    pasteboard.replaceExternally(with: .init(plainText: "old baseline", changeCount: 2))
    let start = ContinuousClock.now
    await controller.testingPollExternalClipboardIfNeeded(at: start)
    if ignoreNext {
      await controller.ignoreNextExternalClipboardChange()
    } else {
      await controller.setClipboardCapturePaused(true)
      await controller.setClipboardCapturePaused(false)
      await controller.testingStopExternalClipboardMonitor()
    }
    await controller.testingPollExternalClipboardIfNeeded(at: start + .seconds(1))
    #expect(try await store.snapshot().records.isEmpty)
    #expect(pasteboard.payloadReadCount == 1)

    pasteboard.replaceExternally(with: .init(plainText: "new copy", changeCount: 3))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .seconds(2))
    let records = try await store.snapshot().records
    if ignoreNext { #expect(records.isEmpty) }
    else { #expect(records.map(\.record.payload) == [.text("new copy")]) }
    await controller.stop()
  }

  @Test
  func changingFocusDiscardsTheOldCopyInsteadOfReattributingIt() async throws {
    let focus = ClipboardFocusProbe()
    let (controller, pasteboard, store) = await makeHarness(focus: focus)
    pasteboard.failedReadsRemaining = 1
    pasteboard.replaceExternally(with: .init(plainText: "copy from A", changeCount: 2))
    let start = ContinuousClock.now
    await controller.testingPollExternalClipboardIfNeeded(at: start)
    focus.snapshot.bundleIdentifier = "com.example.OtherEditor"
    focus.snapshot.processIdentifier = 43
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(25))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(100))
    #expect(try await store.snapshot().records.isEmpty)
    #expect(pasteboard.payloadReadCount == 1)

    pasteboard.replaceExternally(with: .init(plainText: "copy from B", changeCount: 3))
    await controller.testingPollExternalClipboardIfNeeded(at: start + .milliseconds(150))
    let records = try await store.snapshot().records
    #expect(records.map(\.record.payload) == [.text("copy from B")])
    #expect(records.first?.record.provenance.sourceBundleIdentifier == "com.example.OtherEditor")
    await controller.stop()
  }

  @Test
  func retriesAFailedHistoryWrite() async throws {
    let persistence = ClipboardRetryPersistence()
    let store = RecordStore(persistence: persistence)
    let (controller, pasteboard, _) = await makeHarness(store: store)
    pasteboard.replaceExternally(with: .init(plainText: "saved after retry", changeCount: 2))
    await controller.testingPollExternalClipboardIfNeeded()
    #expect(try await store.snapshot().records.map(\.record.payload) == [.text("saved after retry")])
    #expect(pasteboard.payloadReadCount == 1)
    await controller.stop()
  }

  @Test(arguments: [false, true])
  func capturesConsecutiveCopiesWhilePersistenceIsBlockedAndDrains(stop: Bool) async throws {
    let persistence = ClipboardBlockingPersistence()
    let store = RecordStore(persistence: persistence)
    let (controller, pasteboard, _) = await makeHarness(store: store)
    pasteboard.replaceExternally(with: .init(plainText: "first", changeCount: 2))
    await controller.testingPollExternalClipboardIfNeeded(waitForPersistence: false)
    await persistence.waitUntilWriting()
    pasteboard.replaceExternally(with: .init(plainText: "second", changeCount: 3))
    await controller.testingPollExternalClipboardIfNeeded(waitForPersistence: false)
    pasteboard.replaceExternally(with: .init(plainText: "third", changeCount: 4))
    await controller.testingPollExternalClipboardIfNeeded(waitForPersistence: false)
    #expect(pasteboard.payloadReadCount == 3)

    let drain = Task {
      if stop { await controller.stop() }
      else { await controller.setClipboardCapturePaused(true) }
    }
    await persistence.releaseWrite()
    await drain.value
    let records = try await store.snapshot().records
    #expect(records.count == 3)
    for text in ["first", "second", "third"] {
      #expect(records.contains { $0.record.payload == .text(text) })
    }
    pasteboard.replaceExternally(with: .init(plainText: "after pausing", changeCount: 5))
    await controller.testingPollExternalClipboardIfNeeded()
    #expect(try await store.snapshot().records.count == 3)
    await controller.stop()
  }

  @Test
  func queueAndCaptureControlsLeaveTheSystemPasteboardUntouched() async throws {
    let store = RecordStore()
    _ = try await store.ingest(
      RecordDraft(payload: .text("queued output"), provenance: .init(source: .init(kind: .user))),
      into: [RecordCollection.inboxID])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let customType = NSPasteboard.PasteboardType("dev.rill.test.native-copy")
    let item = NSPasteboardItem()
    #expect(item.setString("native copy", forType: .string))
    #expect(item.setData(Data([1, 2, 3]), forType: customType))
    #expect(pasteboard.writeObjects([item]))
    let baseline = pasteboard.changeCount
    let controller = makeController(pasteboard: SystemClipboardPort(pasteboard: pasteboard), store: store)
    await controller.start(initialClipboardCaptureEnabled: true)
    await controller.testingStopExternalClipboardMonitor()
    #expect(pasteboard.changeCount == baseline)
    #expect(pasteboard.string(forType: .string) == "native copy")

    pasteboard.clearContents()
    let copiedItem = NSPasteboardItem()
    #expect(copiedItem.setString("native copy", forType: .string))
    #expect(copiedItem.setData(Data([1, 2, 3]), forType: customType))
    #expect(pasteboard.writeObjects([copiedItem]))
    let copied = pasteboard.changeCount
    await controller.testingPollExternalClipboardIfNeeded()
    #expect(try await store.snapshot().records.contains { $0.record.payload == .text("native copy") })
    await controller.setClipboardCapturePaused(true)
    await controller.setClipboardCapturePaused(false)
    await controller.testingStopExternalClipboardMonitor()
    await controller.ignoreNextExternalClipboardChange()
    await controller.stop()
    #expect(pasteboard.changeCount == copied)
    #expect(pasteboard.string(forType: .string) == "native copy")
    #expect(pasteboard.data(forType: customType) == Data([1, 2, 3]))
  }

  @Test
  func panelShortcutWorksWithCaptureDisabledAndStopsAtShutdown() async throws {
    let eventBus = EventBus()
    let pasteboard = RecordCaptureTestPasteboard(snapshot: .init(plainText: "native copy", changeCount: 1))
    let controller = makeController(pasteboard: pasteboard, store: RecordStore(), eventBus: eventBus)
    await controller.start(initialClipboardCaptureEnabled: false)
    let stream = await eventBus.stream()
    var iterator = stream.makeAsyncIterator()
    let marker = RillEvent.contextCaptured(run: .init(runID: UUID()), snapshot: .empty)
    await controller.testingHandleHotkey(.recordPanelRequested)
    await eventBus.publish(marker)
    var events: [RillEvent] = []
    while let event = await iterator.next(), event != marker { events.append(event) }
    #expect(events == [.recordPanelRequested])
    #expect(pasteboard.payloadReadCount == 0)
    #expect(pasteboard.currentSnapshot().changeCount == 1)
    await controller.stop()
    await controller.testingHandleHotkey(.recordPanelRequested)
    await eventBus.publish(marker)
    #expect(await iterator.next() == marker)
  }

  @Test(arguments: [
    RecordPayload.text("explicit text"),
    .image(Data([1, 2, 3])),
    .files([URL(fileURLWithPath: "/tmp/rill-explicit-output")]),
  ], [false, true])
  func explicitNextOutputRequiresTheOriginalTargetWhileCaptureIsPaused(
    payload: RecordPayload, targetChanged: Bool
  ) async throws {
    let store = RecordStore()
    let queue = try await store.createCollection(name: "Output", preset: .queue)
    let record = try await store.ingest(
      RecordDraft(payload: payload, provenance: .init(source: .init(kind: .user))), into: [queue.id])
    try await store.replaceDeliveryRules([
      DeliveryRouteRule(matcher: .init(), priority: 0, sourceCollectionIDs: [queue.id], sink: .focusedApplication)
    ])
    let eventBus = EventBus()
    let focus = ClipboardFocusProbe().snapshot
    var changedFocus = focus
    changedFocus.bundleIdentifier = "com.example.OtherEditor"
    changedFocus.processIdentifier = 43
    let executionFocus = targetChanged ? changedFocus : focus
    let probe = ExplicitRecordOutputProbe()
    let coordinator = SessionCoordinator(
      contextProvider: RecordCaptureTestContextProvider(),
      privacyContextProvider: { ContextSnapshot(focus: executionFocus, clipboard: .init(plainText: "native copy", changeCount: 1)) },
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: [ExplicitRecordOutputAction(probe: probe)]),
      candidateResolver: CandidateResolver(eventBus: eventBus), recordStore: store, eventBus: eventBus)
    let pasteboard = RecordCaptureTestPasteboard(snapshot: .init(plainText: "native copy", changeCount: 1))
    let controller = SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(), pasteboard: pasteboard, recordStore: store,
      sessionCoordinator: coordinator, eventBus: eventBus,
      privacySettingsProvider: { .defaults }, focusSnapshotProvider: { focus },
      accessibilityChecker: { true })
    await controller.start(initialClipboardCaptureEnabled: false)
    #expect(await probe.payloads.isEmpty)
    #expect(pasteboard.currentSnapshot().changeCount == 1)
    await controller.deliverNextRecord()
    let delivered = try #require(try await store.record(id: record.id))
    if targetChanged {
      #expect(await probe.payloads.isEmpty)
      #expect(delivered.memberships.first?.state == .active)
      #expect(delivered.activity.useCount == 0)
    } else {
      #expect(await probe.payloads == [payload])
      #expect(delivered.memberships.first?.state == .consumed)
      #expect(delivered.activity.useCount == 1)
    }
    await controller.stop()
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["RILL_CLIPBOARD_LATENCY"] == "1"))
  func realPasteboardToEncryptedHistoryLatency() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rill-clipboard-latency-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = try SQLitePersistenceStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"),
      localDataProtector: AESGCMDataProtector(
        key: Data(repeating: 0x39, count: AESGCMDataProtector.keyByteCount)))
    let store = RecordStore(persistence: persistence)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let port = SystemClipboardPort(pasteboard: pasteboard)
    let controller = makeController(pasteboard: port, store: store)
    await controller.start(initialClipboardCaptureEnabled: true)
    let catalog = try await store.catalogStream()
    let pasteboardName = pasteboard.name
    do {
      let timings = try await withThrowingTaskGroup(of: [Double].self) { group in
        group.addTask { @MainActor @Sendable in
          let pasteboard = NSPasteboard(name: pasteboardName)
          var iterator = catalog.makeAsyncIterator()
          _ = await iterator.next()
          var milliseconds: [Double] = []
          for index in 0..<24 {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            pasteboard.clearContents()
            #expect(pasteboard.setString("Clipboard latency fixture \(index)", forType: .string))
            let snapshot = try #require(await iterator.next())
            #expect(snapshot.records.count == index + 1)
            let duration = start.duration(to: .now).components
            milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
          }
          return milliseconds
        }
        group.addTask {
          try await Task.sleep(for: .seconds(25))
          throw ClipboardLatencyTimeout()
        }
        defer { group.cancelAll() }
        return try #require(try await group.next())
      }
      let sorted = timings.sorted()
      let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
      print("Clipboard capture latency: samples=\(timings.count) p50_ms=\(sorted[(sorted.count - 1) / 2]) p95_ms=\(p95) max_ms=\(sorted.last ?? 0)")
      #expect(p95 < 150)
      #expect(sorted.last.map { $0 < 250 } == true)
      let records = try await store.snapshot().records
      for index in 0..<24 {
        #expect(records.contains { $0.record.payload == .text("Clipboard latency fixture \(index)") })
      }
      await controller.stop()
    } catch {
      await controller.stop()
      throw error
    }
  }

  private func makeHarness(store: RecordStore = RecordStore(), focus: ClipboardFocusProbe? = nil) async
    -> (SystemClipboardCaptureController, RecordCaptureTestPasteboard, RecordStore)
  {
    let pasteboard = RecordCaptureTestPasteboard(snapshot: .init(plainText: "initial", changeCount: 1))
    let controller = makeController(pasteboard: pasteboard, store: store, focus: focus)
    await controller.start(initialClipboardCaptureEnabled: true)
    await controller.testingStopExternalClipboardMonitor()
    return (controller, pasteboard, store)
  }

  private func makeController(
    pasteboard: any SystemClipboardAccess, store: RecordStore, focus: ClipboardFocusProbe? = nil,
    eventBus: EventBus = EventBus()
  )
    -> SystemClipboardCaptureController
  {
    let context = RecordCaptureTestContextProvider()
    let coordinator = SessionCoordinator(
      contextProvider: context,
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: CandidateResolver(eventBus: eventBus),
      recordStore: store,
      eventBus: eventBus)
    return SystemClipboardCaptureController(
      hotkeyTap: HotkeyEventTap(), pasteboard: pasteboard,
      recordStore: store, sessionCoordinator: coordinator, eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: {
        if let focus { return await focus.snapshot }
        return .init(applicationName: "Editor", bundleIdentifier: "com.example.Editor",
              processIdentifier: 42, focusedRole: nil, selectedText: "", secureInput: false)
      },
      accessibilityChecker: { false })
  }
}

@MainActor
private final class ClipboardFocusProbe {
  var snapshot = FocusSnapshot(
    applicationName: "Editor", bundleIdentifier: "com.example.Editor", processIdentifier: 42,
    focusedRole: nil, selectedText: "", secureInput: false)
}

private struct ClipboardLatencyTimeout: Error {}

private actor ClipboardRetryPersistence: RecordGraphPersistenceStore {
  private var hasFailed = false

  func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }
  func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64 {
    if !hasFailed {
      hasFailed = true
      throw RecordStoreError.persistenceUnavailable
    }
    return (snapshot.expectedRevision ?? 0) + 1
  }
  func removeRecordGraph() async throws -> RecordGraphRemovalResult { .removed }
}

private actor ClipboardBlockingPersistence: RecordGraphPersistenceStore {
  private var writeStarted = false
  private var writeGate: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func loadRecordGraph() async throws -> RecordGraphPersistenceReadSnapshot { .empty }
  func replaceRecordGraph(with snapshot: RecordGraphPersistenceWriteSnapshot) async throws -> Int64 {
    if !writeStarted {
      writeStarted = true
      for observer in observers { observer.resume() }
      observers.removeAll()
      await withCheckedContinuation { writeGate = $0 }
    }
    return (snapshot.expectedRevision ?? 0) + 1
  }
  func removeRecordGraph() async throws -> RecordGraphRemovalResult { .removed }
  func waitUntilWriting() async {
    guard !writeStarted else { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func releaseWrite() {
    writeGate?.resume()
    writeGate = nil
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

  func testSelectedDeliveryWritesOnlyWhenExplicitlyRequestedAndRestoresClipboard() async throws {
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
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: { focus },
      accessibilityChecker: { true }
    )

    await controller.start(initialClipboardCaptureEnabled: true)
    let beforeOutput = await MainActor.run { pasteboard.currentSnapshot() }
    XCTAssertEqual(beforeOutput.plainText, "existing")
    XCTAssertEqual(beforeOutput.changeCount, 1)

    await controller.deliverSelectedRecord(subject, to: target)

    let finalSnapshot = await MainActor.run { pasteboard.currentSnapshot() }
    XCTAssertEqual(finalSnapshot.plainText, "existing")
    XCTAssertEqual(finalSnapshot.changeCount, 3)
    let delivered = await probe.snapshot()
    XCTAssertEqual(delivered, ["selected record"])
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
      recordStore: store,
      sessionCoordinator: coordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusSnapshotProvider: { focus },
      accessibilityChecker: { false }
    )

    await controller.start(initialClipboardCaptureEnabled: true)
    await controller.testingStopExternalClipboardMonitor()
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

private actor ExplicitRecordOutputProbe {
  private(set) var payloads: [RecordPayload] = []
  func record(_ payload: RecordPayload) { payloads.append(payload) }
}

private struct ExplicitRecordOutputAction: OutputAction {
  let id = RecordActionID.focusedApplicationInsert
  let probe: ExplicitRecordOutputProbe
  func execute(record: RecordDraft, context: ActionContext) async throws -> ActionResult {
    await probe.record(record.payload)
    return .injected
  }
}
