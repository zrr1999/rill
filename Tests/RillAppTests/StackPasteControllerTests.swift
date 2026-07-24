import XCTest

@testable import RillApp
@testable import RillCore
@testable import RillPlatform
@testable import RillRuntime

private struct StackPasteTestContextProvider: ContextProvider {
  func captureContext() async -> ContextSnapshot { .empty }
}

private func makeProjectedTemporaryWriteTransaction(
  temporaryChangeCount: Int
) -> PasteboardController.TemporaryWriteTransaction {
  PasteboardController.TemporaryWriteTransaction(
    preservedContents: .init(items: []),
    temporaryChangeCount: temporaryChangeCount
  )
}

private struct RawPasteboardRepresentation: Equatable {
  var typeName: String
  var data: Data
}

@MainActor
private func rawPasteboardContents(
  _ pasteboard: NSPasteboard
) -> [[RawPasteboardRepresentation]] {
  (pasteboard.pasteboardItems ?? []).map { item in
    item.types.compactMap { type in
      item.data(forType: type).map {
        RawPasteboardRepresentation(typeName: type.rawValue, data: $0)
      }
    }
  }
}

private actor PasteOperationGate {
  private var started = false
  private var startedContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func hold() async {
    started = true
    startedContinuation?.resume()
    startedContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor CancellablePasteOperationProbe {
  private var started = false
  private var startedContinuation: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func runUntilCancelled() async {
    started = true
    startedContinuation?.resume()
    startedContinuation = nil
    try? await Task.sleep(for: .seconds(30))
  }
}

private actor ActiveRouteContextGate {
  private let routeContext: ClipboardRouteContext
  private var requestCount = 0
  private var firstRequestStarted = false
  private var firstRequestStartedContinuation: CheckedContinuation<Void, Never>?
  private var firstRequestReleaseContinuation: CheckedContinuation<Void, Never>?

  init(routeContext: ClipboardRouteContext) {
    self.routeContext = routeContext
  }

  func resolve() async -> ClipboardRouteContext {
    requestCount += 1
    if requestCount == 1 {
      firstRequestStarted = true
      firstRequestStartedContinuation?.resume()
      firstRequestStartedContinuation = nil
      await withCheckedContinuation { continuation in
        firstRequestReleaseContinuation = continuation
      }
    }
    return routeContext
  }

  func waitUntilFirstRequestStarts() async {
    guard !firstRequestStarted else { return }
    await withCheckedContinuation { continuation in
      firstRequestStartedContinuation = continuation
    }
  }

  func releaseFirstRequest() {
    firstRequestReleaseContinuation?.resume()
    firstRequestReleaseContinuation = nil
  }

  func requests() -> Int {
    requestCount
  }
}

private actor AsyncCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}

private actor AsyncCallCounter {
  private var count = 0

  @discardableResult
  func increment() -> Int {
    count += 1
    return count
  }

  func value() -> Int {
    count
  }
}

private actor StackPasteEventProbe {
  private var events: [RillEvent] = []

  func append(_ event: RillEvent) {
    events.append(event)
  }

  func snapshot() -> [RillEvent] {
    events
  }
}

private actor ClipboardCaptureControlProbe {
  private var states: [ClipboardCaptureControlSnapshot] = []
  private var stateWaiters: [(ClipboardCaptureControlState, CheckedContinuation<Void, Never>)] = []

  func append(_ snapshot: ClipboardCaptureControlSnapshot) {
    states.append(snapshot)
    let matchingWaiters = stateWaiters.filter { $0.0 == snapshot.state }
    stateWaiters.removeAll { $0.0 == snapshot.state }
    for waiter in matchingWaiters {
      waiter.1.resume()
    }
  }

  func snapshot() -> [ClipboardCaptureControlSnapshot] {
    states
  }

  func waitUntilObserved(_ state: ClipboardCaptureControlState) async {
    guard !states.contains(where: { $0.state == state }) else { return }
    await withCheckedContinuation { continuation in
      stateWaiters.append((state, continuation))
    }
  }
}

private actor FocusIdentitySampleProbe {
  private var sample: FocusPrivacyIdentitySample
  private var queuedSamples: [FocusPrivacyIdentitySample] = []

  init(sample: FocusPrivacyIdentitySample) {
    self.sample = sample
  }

  func current() -> FocusPrivacyIdentitySample {
    if !queuedSamples.isEmpty {
      return queuedSamples.removeFirst()
    }
    return sample
  }

  func update(_ sample: FocusPrivacyIdentitySample) {
    self.sample = sample
  }

  func enqueue(_ samples: [FocusPrivacyIdentitySample]) {
    queuedSamples.append(contentsOf: samples)
  }
}

private actor StackPasteCommandProbe {
  private var sendCount = 0

  func send() -> Bool {
    sendCount += 1
    return true
  }

  func snapshot() -> Int {
    sendCount
  }
}

private actor PrivacySettingsProbe {
  private var settings: PrivacyPolicySettings

  init(settings: PrivacyPolicySettings) {
    self.settings = settings
  }

  func current() -> PrivacyPolicySettings {
    settings
  }

  func update(_ settings: PrivacyPolicySettings) {
    self.settings = settings
  }
}

@MainActor
private final class PrivacyTestPasteboard: StackPastePasteboard {
  private var descriptorValue: ClipboardDescriptor
  private var snapshotValue: ClipboardSnapshot
  private var ownedChangeCounts: Set<Int> = []
  private var preservedSnapshotsByTemporaryChangeCount: [Int: ClipboardSnapshot] = [:]
  private var replacementOnNextRead: ClipboardSnapshot?
  private var replacementBeforeNextWrite: ClipboardSnapshot?
  private var pauseNextPayloadRead = false
  private var payloadReadStarted = false
  private var payloadReadStartedContinuation: CheckedContinuation<Void, Never>?
  private var payloadReadResumeContinuation: CheckedContinuation<Void, Never>?
  private var pauseNextDescriptorRead = false
  private var descriptorReadStarted = false
  private var descriptorReadStartedContinuation: CheckedContinuation<Void, Never>?
  private var descriptorReadResumeContinuation: CheckedContinuation<Void, Never>?
  private var pauseNextWrite = false
  private var restoreFailuresRemaining = 0
  private var externalSnapshotBeforeNextRestore: ClipboardSnapshot?
  private var externalSnapshotAfterRestoreFailure: ClipboardSnapshot?
  private var writeStarted = false
  private var writeStartedContinuation: CheckedContinuation<Void, Never>?
  private var writeResumeContinuation: CheckedContinuation<Void, Never>?
  private(set) var payloadReadCount = 0
  private(set) var descriptorReadCount = 0
  private(set) var writeCallCount = 0
  private(set) var restoreCallCount = 0

  init(snapshot: ClipboardSnapshot) {
    descriptorValue = ClipboardDescriptor(snapshot: snapshot)
    snapshotValue = snapshot
  }

  func currentClipboardDescriptor() async -> ClipboardDescriptor {
    descriptorReadCount += 1
    descriptorReadStarted = true
    descriptorReadStartedContinuation?.resume()
    descriptorReadStartedContinuation = nil
    if pauseNextDescriptorRead {
      pauseNextDescriptorRead = false
      await withCheckedContinuation { continuation in
        descriptorReadResumeContinuation = continuation
      }
    }
    return descriptorValue
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> ClipboardSnapshot? {
    payloadReadCount += 1
    payloadReadStarted = true
    payloadReadStartedContinuation?.resume()
    payloadReadStartedContinuation = nil
    if pauseNextPayloadRead {
      pauseNextPayloadRead = false
      await withCheckedContinuation { continuation in
        payloadReadResumeContinuation = continuation
      }
    }
    if let replacementOnNextRead {
      self.replacementOnNextRead = nil
      snapshotValue = replacementOnNextRead
      descriptorValue = ClipboardDescriptor(snapshot: replacementOnNextRead)
      return nil
    }
    return descriptorValue.changeCount == expected ? snapshotValue : nil
  }

  func currentClipboardSnapshot() async -> ClipboardSnapshot {
    payloadReadCount += 1
    return snapshotValue
  }

  func peekSnapshot() -> ClipboardSnapshot {
    snapshotValue
  }

  func writeClipboardSnapshot(
    _ snapshot: ClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async -> Int? {
    writeCallCount += 1
    if let replacementBeforeNextWrite {
      self.replacementBeforeNextWrite = nil
      snapshotValue = replacementBeforeNextWrite
      descriptorValue = ClipboardDescriptor(snapshot: replacementBeforeNextWrite)
    }
    guard descriptorValue.changeCount == expected,
      descriptorValue.protections.isEmpty
    else { return nil }
    let nextChangeCount = descriptorValue.changeCount + 1
    var written = snapshot
    written.changeCount = nextChangeCount
    snapshotValue = written
    descriptorValue = ClipboardDescriptor(snapshot: written)
    ownedChangeCounts.insert(nextChangeCount)
    writeStarted = true
    writeStartedContinuation?.resume()
    writeStartedContinuation = nil
    if pauseNextWrite {
      pauseNextWrite = false
      await withCheckedContinuation { continuation in
        writeResumeContinuation = continuation
      }
    }
    return nextChangeCount
  }

  func beginTemporaryClipboardWrite(
    _ snapshot: ClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async throws -> PasteboardController.TemporaryWriteTransaction {
    let preservedSnapshot = snapshotValue
    guard let temporaryChangeCount = await writeClipboardSnapshot(
      snapshot,
      ifChangeCountIs: expected
    ) else {
      throw PasteboardController.ConditionalWriteError.changeCountChanged
    }
    preservedSnapshotsByTemporaryChangeCount[temporaryChangeCount] = preservedSnapshot
    return makeProjectedTemporaryWriteTransaction(
      temporaryChangeCount: temporaryChangeCount
    )
  }

  func restoreTemporaryClipboardWrite(
    _ transaction: PasteboardController.TemporaryWriteTransaction,
    ifChangeCountIs expected: Int
  ) async -> PasteboardController.TemporaryRestoreOutcome {
    if let externalSnapshotBeforeNextRestore {
      self.externalSnapshotBeforeNextRestore = nil
      snapshotValue = externalSnapshotBeforeNextRestore
      descriptorValue = ClipboardDescriptor(snapshot: externalSnapshotBeforeNextRestore)
    }
    guard descriptorValue.changeCount == expected else {
      preservedSnapshotsByTemporaryChangeCount.removeValue(
        forKey: transaction.temporaryChangeCount
      )
      return .skippedChangeCount
    }
    guard let snapshot = preservedSnapshotsByTemporaryChangeCount[
      transaction.temporaryChangeCount
    ] else { return .writeFailed(retryChangeCount: expected) }
    restoreCallCount += 1
    if restoreFailuresRemaining > 0 {
      restoreFailuresRemaining -= 1
      let retryChangeCount = descriptorValue.changeCount + 1
      var partialSnapshot = snapshotValue
      partialSnapshot.changeCount = retryChangeCount
      snapshotValue = partialSnapshot
      descriptorValue = ClipboardDescriptor(snapshot: partialSnapshot)
      ownedChangeCounts.insert(retryChangeCount)
      externalSnapshotBeforeNextRestore = externalSnapshotAfterRestoreFailure
      externalSnapshotAfterRestoreFailure = nil
      return .writeFailed(retryChangeCount: retryChangeCount)
    }
    let restoredChangeCount = await writeClipboardSnapshot(
      snapshot,
      ifChangeCountIs: expected
    )
    guard restoredChangeCount != nil else {
      return .writeFailed(retryChangeCount: descriptorValue.changeCount)
    }
    preservedSnapshotsByTemporaryChangeCount.removeValue(
      forKey: transaction.temporaryChangeCount
    )
    return .restored
  }

  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool {
    ownedChangeCounts.contains(changeCount)
  }

  func replaceOnNextRead(with snapshot: ClipboardSnapshot) {
    replacementOnNextRead = snapshot
  }

  func replaceBeforeNextWrite(with snapshot: ClipboardSnapshot) {
    replacementBeforeNextWrite = snapshot
  }

  func setExternalSnapshot(_ snapshot: ClipboardSnapshot) {
    snapshotValue = snapshot
    descriptorValue = ClipboardDescriptor(snapshot: snapshot)
  }

  func setPauseNextPayloadRead() {
    pauseNextPayloadRead = true
    payloadReadStarted = false
  }

  func waitUntilPayloadReadStarted() async {
    guard !payloadReadStarted else { return }
    await withCheckedContinuation { continuation in
      payloadReadStartedContinuation = continuation
    }
  }

  func resumePausedPayloadRead() {
    payloadReadResumeContinuation?.resume()
    payloadReadResumeContinuation = nil
  }

  func setPauseNextDescriptorRead() {
    pauseNextDescriptorRead = true
    descriptorReadStarted = false
  }

  func waitUntilDescriptorReadStarted() async {
    guard !descriptorReadStarted else { return }
    await withCheckedContinuation { continuation in
      descriptorReadStartedContinuation = continuation
    }
  }

  func resumePausedDescriptorRead() {
    descriptorReadResumeContinuation?.resume()
    descriptorReadResumeContinuation = nil
  }

  func setPauseNextWrite() {
    pauseNextWrite = true
    writeStarted = false
  }

  func failNextRestoreAttempts(
    _ count: Int,
    thenExternalSnapshot: ClipboardSnapshot? = nil
  ) {
    restoreFailuresRemaining = count
    externalSnapshotAfterRestoreFailure = thenExternalSnapshot
  }

  func waitUntilWriteStarted() async {
    guard !writeStarted else { return }
    await withCheckedContinuation { continuation in
      writeStartedContinuation = continuation
    }
  }

  func resumePausedWrite() {
    writeResumeContinuation?.resume()
    writeResumeContinuation = nil
  }
}

@MainActor
private final class PausedWritePasteboard: StackPastePasteboard {
  private var currentSnapshotValue: ClipboardSnapshot
  private var ownedChangeCounts: Set<Int> = []
  private var preservedSnapshotsByTemporaryChangeCount: [Int: ClipboardSnapshot] = [:]
  private var nextChangeCount: Int
  private var pauseNextWrite = false
  private var writeStarted = false
  private var writeStartedContinuation: CheckedContinuation<Void, Never>?
  private var writeResumeContinuation: CheckedContinuation<Void, Never>?
  private(set) var restoreCallCount = 0
  private(set) var payloadReadCount = 0

  init(initialSnapshot: ClipboardSnapshot, nextChangeCount: Int = 2) {
    self.currentSnapshotValue = initialSnapshot
    self.nextChangeCount = nextChangeCount
  }

  func currentClipboardSnapshot() async -> ClipboardSnapshot {
    payloadReadCount += 1
    return currentSnapshotValue
  }

  func currentClipboardDescriptor() async -> ClipboardDescriptor {
    ClipboardDescriptor(snapshot: currentSnapshotValue)
  }

  func readClipboardSnapshot(ifChangeCountIs expected: Int) async -> ClipboardSnapshot? {
    payloadReadCount += 1
    return currentSnapshotValue.changeCount == expected ? currentSnapshotValue : nil
  }

  func peekSnapshot() -> ClipboardSnapshot {
    currentSnapshotValue
  }

  func writeClipboardSnapshot(
    _ snapshot: ClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async -> Int? {
    guard currentSnapshotValue.changeCount == expected,
      currentSnapshotValue.protections.isEmpty
    else { return nil }
    let changeCount = nextChangeCount
    nextChangeCount += 1
    var writtenSnapshot = snapshot
    writtenSnapshot.changeCount = changeCount
    currentSnapshotValue = writtenSnapshot
    ownedChangeCounts.insert(changeCount)
    writeStarted = true
    writeStartedContinuation?.resume()
    writeStartedContinuation = nil
    if pauseNextWrite {
      pauseNextWrite = false
      await withCheckedContinuation { continuation in
        writeResumeContinuation = continuation
      }
    }
    return changeCount
  }

  func beginTemporaryClipboardWrite(
    _ snapshot: ClipboardSnapshot,
    ifChangeCountIs expected: Int
  ) async throws -> PasteboardController.TemporaryWriteTransaction {
    let preservedSnapshot = currentSnapshotValue
    guard let temporaryChangeCount = await writeClipboardSnapshot(
      snapshot,
      ifChangeCountIs: expected
    ) else {
      throw PasteboardController.ConditionalWriteError.changeCountChanged
    }
    preservedSnapshotsByTemporaryChangeCount[temporaryChangeCount] = preservedSnapshot
    return makeProjectedTemporaryWriteTransaction(
      temporaryChangeCount: temporaryChangeCount
    )
  }

  func restoreTemporaryClipboardWrite(
    _ transaction: PasteboardController.TemporaryWriteTransaction,
    ifChangeCountIs expected: Int
  ) async -> PasteboardController.TemporaryRestoreOutcome {
    guard currentSnapshotValue.changeCount == expected else { return .skippedChangeCount }
    guard let snapshot = preservedSnapshotsByTemporaryChangeCount.removeValue(
      forKey: transaction.temporaryChangeCount
    ) else { return .writeFailed(retryChangeCount: expected) }
    restoreCallCount += 1
    let restoredChangeCount = nextChangeCount
    nextChangeCount += 1
    var restoredSnapshot = snapshot
    restoredSnapshot.changeCount = restoredChangeCount
    currentSnapshotValue = restoredSnapshot
    ownedChangeCounts.insert(restoredChangeCount)
    return .restored
  }

  func ownsClipboardChangeCount(_ changeCount: Int) async -> Bool {
    ownedChangeCounts.contains(changeCount)
  }

  func setPauseNextWrite() {
    pauseNextWrite = true
    writeStarted = false
  }

  func waitUntilWriteStarted() async {
    guard !writeStarted else { return }
    await withCheckedContinuation { continuation in
      writeStartedContinuation = continuation
    }
  }

  func resumePausedWrite() {
    writeResumeContinuation?.resume()
    writeResumeContinuation = nil
  }
}

final class StackPasteControllerTests: XCTestCase {
  @MainActor
  func testProductionPasteboardAdapterRestoresAllRepresentationsAfterPreviewReplacement() async throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let firstItem = NSPasteboardItem()
    firstItem.setString("rich original", forType: .string)
    firstItem.setData(Data("{\\rtf1 rich original}".utf8), forType: .rtf)
    firstItem.setData(
      Data([0x00, 0xFF, 0x10, 0x80]),
      forType: .init("com.example.rill-stack-private")
    )
    let secondItem = NSPasteboardItem()
    secondItem.setData(Data([0x25, 0x50, 0x44, 0x46]), forType: .pdf)
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))
    let originalChangeCount = pasteboard.changeCount
    let originalContents = rawPasteboardContents(pasteboard)
    let adapter: any StackPastePasteboard = PasteboardController(pasteboard: pasteboard)

    let transaction = try await adapter.beginTemporaryClipboardWrite(
      ClipboardSnapshot(plainText: "first preview", changeCount: 0),
      ifChangeCountIs: originalChangeCount
    )
    let updatedChangeCountCandidate = await adapter.writeClipboardSnapshot(
      ClipboardSnapshot(plainText: "second preview", changeCount: 0),
      ifChangeCountIs: transaction.temporaryChangeCount
    )
    let updatedChangeCount = try XCTUnwrap(updatedChangeCountCandidate)
    XCTAssertEqual(pasteboard.string(forType: .string), "second preview")

    let restoreOutcome = await adapter.restoreTemporaryClipboardWrite(
      transaction,
      ifChangeCountIs: updatedChangeCount
    )

    XCTAssertEqual(restoreOutcome, .restored)
    XCTAssertEqual(rawPasteboardContents(pasteboard), originalContents)
  }

  func testStoppingClipboardConsumerDoesNotUninstallApplicationOwnedTap() async throws {
    let hotkeyTap = HotkeyEventTap()
    let lifecycle = GlobalInputLifecycleProbe(installOutcomes: [true, false])
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 1),
      focus: makeFocus(),
      hotkeyTap: hotkeyTap
    )
    let owner = GlobalInputOwner(
      hotkeyTap: hotkeyTap,
      installTap: {
        let installed = lifecycle.install()
        hotkeyTap.testingEmit(.clipboardPanelRequested)
        return installed
      },
      uninstallTap: {
        lifecycle.recordUninstall()
      },
      permissionChecker: { true },
      capabilityObserver: { capability in
        lifecycle.record(capability)
      }
    )
    let stream = await fixture.eventBus.stream()
    let probe = StackPasteEventProbe()
    let eventTask = Task {
      for await event in stream {
        await probe.append(event)
      }
    }
    defer { eventTask.cancel() }

    await fixture.controller.start(initialClipboardCaptureEnabled: true)
    await owner.start()
    for _ in 0..<100 {
      let events = await probe.snapshot()
      if events.contains(where: {
        if case .clipboardPanelRequested = $0 { true } else { false }
      }) {
        break
      }
      await Task.yield()
    }

    let events = await probe.snapshot()
    XCTAssertTrue(
      events.contains(where: {
        if case .clipboardPanelRequested = $0 { true } else { false }
      }),
      "An event emitted as the shared tap installs must reach the pre-registered stream."
    )
    await fixture.controller.stop()
    XCTAssertEqual(lifecycle.uninstallCount, 0)

    hotkeyTap.testingEmit(.globalInputUnavailable)
    for _ in 0..<100 {
      if lifecycle.capabilities == [.available, .installationFailed] { break }
      await Task.yield()
    }
    XCTAssertEqual(lifecycle.installCount, 2)
    XCTAssertEqual(lifecycle.capabilities, [.available, .installationFailed])

    await owner.stop()
    XCTAssertEqual(lifecycle.uninstallCount, 1)
  }

  func testDisabledColdStartDoesNotReadClipboardFocusOrPrivacyAndKeepsSharedMonitors()
    async
  {
    let focusCalls = AsyncCallCounter()
    let privacyCalls = AsyncCallCounter()
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "cold-start secret", changeCount: 1),
      focus: makeFocus(),
      focusIdentitySampleProvider: {
        await focusCalls.increment()
        return FocusPrivacyIdentitySample(
          focus: makeFocus(),
          applicationActivationRevision: 0
        )
      },
      activeRouteContextProvider: { routeContext },
      privacySettingsProvider: {
        await privacyCalls.increment()
        return .defaults
      }
    )

    await fixture.controller.start(initialClipboardCaptureEnabled: false)
    try? await Task.sleep(for: .milliseconds(900))

    let descriptorReads = await MainActor.run { fixture.pasteboard.descriptorReadCount }
    let payloadReads = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let observedFocusCalls = await focusCalls.value()
    let observedPrivacyCalls = await privacyCalls.value()
    let control = await fixture.controller.testingCaptureControlSnapshot()
    let monitors = await fixture.controller.testingMonitorState()
    XCTAssertEqual(descriptorReads, 0)
    XCTAssertEqual(payloadReads, 0)
    XCTAssertEqual(observedFocusCalls, 0)
    XCTAssertEqual(observedPrivacyCalls, 0)
    XCTAssertEqual(control.state, .paused)
    XCTAssertTrue(monitors.routeRefreshActive)
    XCTAssertFalse(monitors.externalCaptureActive)
    XCTAssertFalse(fixture.hotkeyTap.testingIsClipboardPanelShortcutEnabled())

    await fixture.controller.stop()
    let stoppedMonitors = await fixture.controller.testingMonitorState()
    XCTAssertFalse(stoppedMonitors.routeRefreshActive)
    XCTAssertFalse(stoppedMonitors.externalCaptureActive)
  }

  func testPauseCancelsExternalMonitorWithoutStoppingRouteRefreshOrReadingAcrossTicks()
    async
  {
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "baseline", changeCount: 10),
      focus: makeFocus(),
      activeRouteContextProvider: { routeContext }
    )

    await fixture.controller.start(initialClipboardCaptureEnabled: true)
    for _ in 0..<100 {
      let descriptorReads = await MainActor.run { fixture.pasteboard.descriptorReadCount }
      if descriptorReads >= 3 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await fixture.controller.setClipboardCapturePaused(true)

    let descriptorReadsAfterPause = await MainActor.run {
      fixture.pasteboard.descriptorReadCount
    }
    let monitorsAfterPause = await fixture.controller.testingMonitorState()
    XCTAssertTrue(monitorsAfterPause.routeRefreshActive)
    XCTAssertFalse(monitorsAfterPause.externalCaptureActive)
    XCTAssertFalse(fixture.hotkeyTap.testingIsClipboardPanelShortcutEnabled())

    try? await Task.sleep(for: .milliseconds(900))
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let descriptorReadsAfterCrossingTicks = await MainActor.run {
      fixture.pasteboard.descriptorReadCount
    }
    XCTAssertEqual(descriptorReadsAfterCrossingTicks, descriptorReadsAfterPause)
    await fixture.controller.stop()
  }

  func testDisabledCaptureDropsQueuedClipboardPanelRequestsUntilReenabled() async throws {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "baseline", changeCount: 10),
      focus: makeFocus()
    )
    let stream = await fixture.eventBus.stream()
    let probe = StackPasteEventProbe()
    let eventTask = Task {
      for await event in stream {
        await probe.append(event)
      }
    }
    defer { eventTask.cancel() }

    await fixture.controller.start(initialClipboardCaptureEnabled: false)
    await fixture.controller.testingHandleHotkey(.clipboardPanelRequested)
    try await Task.sleep(for: .milliseconds(20))

    var events = await probe.snapshot()
    XCTAssertFalse(events.contains { if case .clipboardPanelRequested = $0 { true } else { false } })

    await fixture.controller.setClipboardCaptureEnabled(true, preferenceRevision: 1)
    await fixture.controller.testingHandleHotkey(.clipboardPanelRequested)
    try await Task.sleep(for: .milliseconds(20))

    events = await probe.snapshot()
    XCTAssertTrue(events.contains { if case .clipboardPanelRequested = $0 { true } else { false } })
    await fixture.controller.stop()
  }

  func testResumeStartsExternalMonitorFromStableBaselineAndCapturesOnlyNewChanges() async {
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "before disabled start", changeCount: 20),
      focus: makeFocus(),
      activeRouteContextProvider: { routeContext }
    )

    await fixture.controller.start(initialClipboardCaptureEnabled: false)
    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "copied while disabled", changeCount: 21)
    )
    await fixture.controller.setClipboardCapturePaused(false)

    var stored = await fixture.deliveryStack.clipboardSnapshot()
    var monitors = await fixture.controller.testingMonitorState()
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertTrue(monitors.routeRefreshActive)
    XCTAssertTrue(monitors.externalCaptureActive)
    XCTAssertTrue(fixture.hotkeyTap.testingIsClipboardPanelShortcutEnabled())

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "copied after resume", changeCount: 22)
    )
    for _ in 0..<40 {
      stored = await fixture.deliveryStack.clipboardSnapshot()
      if stored.items.map(\.text) == ["copied after resume"] { break }
      try? await Task.sleep(for: .milliseconds(50))
    }

    stored = await fixture.deliveryStack.clipboardSnapshot()
    monitors = await fixture.controller.testingMonitorState()
    XCTAssertEqual(stored.items.map(\.text), ["copied after resume"])
    XCTAssertTrue(monitors.externalCaptureActive)
    await fixture.controller.stop()
  }

  func testExplicitPreStartRequestsWinOverInitialPreferenceAndRemainIdempotent() async {
    let disabledFixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "must stay unread", changeCount: 30),
      focus: makeFocus()
    )
    await disabledFixture.controller.setClipboardCapturePaused(true)
    await disabledFixture.controller.setClipboardCapturePaused(true)
    await disabledFixture.controller.start(initialClipboardCaptureEnabled: true)

    let disabledReads = await MainActor.run {
      disabledFixture.pasteboard.descriptorReadCount
    }
    let disabledControl = await disabledFixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(disabledReads, 0)
    XCTAssertEqual(disabledControl.state, .paused)
    await disabledFixture.controller.stop()

    let enabledFixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "enabled baseline", changeCount: 31),
      focus: makeFocus()
    )
    await enabledFixture.controller.setClipboardCapturePaused(false)
    await enabledFixture.controller.setClipboardCapturePaused(false)
    await enabledFixture.controller.start(initialClipboardCaptureEnabled: false)

    let enabledReads = await MainActor.run { enabledFixture.pasteboard.descriptorReadCount }
    let enabledControl = await enabledFixture.controller.testingCaptureControlSnapshot()
    let enabledMonitors = await enabledFixture.controller.testingMonitorState()
    XCTAssertGreaterThan(enabledReads, 0)
    XCTAssertEqual(enabledControl.state, .active)
    XCTAssertTrue(enabledMonitors.externalCaptureActive)
    await enabledFixture.controller.stop()
  }

  func testExplicitPauseDuringEnabledStartupWinsBeforeMonitorInstallation() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "startup race baseline", changeCount: 35),
      focus: makeFocus()
    )
    await fixture.pasteboard.setPauseNextDescriptorRead()
    let startTask = Task {
      await fixture.controller.start(initialClipboardCaptureEnabled: true)
    }
    await fixture.pasteboard.waitUntilDescriptorReadStarted()

    await fixture.controller.setClipboardCapturePaused(true)
    var control = await fixture.controller.testingCaptureControlSnapshot()
    var monitors = await fixture.controller.testingMonitorState()
    XCTAssertEqual(control.state, .paused)
    XCTAssertFalse(monitors.externalCaptureActive)

    await fixture.pasteboard.resumePausedDescriptorRead()
    await startTask.value

    control = await fixture.controller.testingCaptureControlSnapshot()
    monitors = await fixture.controller.testingMonitorState()
    XCTAssertEqual(control.state, .paused)
    XCTAssertTrue(monitors.routeRefreshActive)
    XCTAssertFalse(monitors.externalCaptureActive)
    await fixture.controller.stop()
  }

  func testNewerPreStartPreferenceWinsOverOlderStartPreferenceInBothDirections() async {
    let disabledFixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "newer disabled", changeCount: 36),
      focus: makeFocus()
    )
    await disabledFixture.controller.setClipboardCaptureEnabled(
      false,
      preferenceRevision: 2
    )
    await disabledFixture.controller.start(
      initialClipboardCaptureEnabled: true,
      preferenceRevision: 1
    )

    var control = await disabledFixture.controller.testingCaptureControlSnapshot()
    var descriptorReads = await MainActor.run {
      disabledFixture.pasteboard.descriptorReadCount
    }
    XCTAssertEqual(control.state, .paused)
    XCTAssertEqual(descriptorReads, 0)
    await disabledFixture.controller.stop()

    let enabledFixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "newer enabled", changeCount: 37),
      focus: makeFocus()
    )
    await enabledFixture.controller.setClipboardCaptureEnabled(
      true,
      preferenceRevision: 2
    )
    await enabledFixture.controller.start(
      initialClipboardCaptureEnabled: false,
      preferenceRevision: 1
    )

    control = await enabledFixture.controller.testingCaptureControlSnapshot()
    descriptorReads = await MainActor.run { enabledFixture.pasteboard.descriptorReadCount }
    XCTAssertEqual(control.state, .active)
    XCTAssertGreaterThan(descriptorReads, 0)
    await enabledFixture.controller.stop()
  }

  func testVersionedCapturePreferenceRejectsStaleUpdates() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "versioned baseline", changeCount: 40),
      focus: makeFocus()
    )
    await fixture.controller.start(
      initialClipboardCaptureEnabled: false,
      preferenceRevision: 10
    )

    await fixture.controller.setClipboardCaptureEnabled(true, preferenceRevision: 9)
    var control = await fixture.controller.testingCaptureControlSnapshot()
    var descriptorReads = await MainActor.run { fixture.pasteboard.descriptorReadCount }
    XCTAssertEqual(control.state, .paused)
    XCTAssertEqual(descriptorReads, 0)

    await fixture.controller.setClipboardCaptureEnabled(true, preferenceRevision: 11)
    control = await fixture.controller.testingCaptureControlSnapshot()
    descriptorReads = await MainActor.run { fixture.pasteboard.descriptorReadCount }
    XCTAssertEqual(control.state, .active)
    XCTAssertGreaterThan(descriptorReads, 0)

    await fixture.controller.setClipboardCaptureEnabled(false, preferenceRevision: 11)
    control = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(control.state, .active)
    await fixture.controller.stop()
  }

  func testClipboardInvalidationRefreshesActiveRouteWithoutSubscribingToSnapshotPayloads() async {
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 1),
      focus: makeFocus(),
      activeRouteContextProvider: { routeContext },
      accessibilityChecker: { true }
    )

    await fixture.controller.start(initialClipboardCaptureEnabled: true)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())

    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(plainText: "queued", changeCount: 2),
      context: routeContext,
      disposition: .historyAndWorkflows
    )

    for _ in 0..<100 where !fixture.hotkeyTap.testingIsPasteInterceptEnabled() {
      await Task.yield()
    }
    XCTAssertTrue(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
    await fixture.controller.stop()
  }

  func testPreviewWriteRestoresOriginalWhenProgrammaticPasteSuspendsMidAwait() async throws {
    let eventBus = EventBus()
    let deliveryStack = DeliveryStack(eventBus: eventBus)
    let candidateResolver = CandidateResolver(eventBus: eventBus)
    let sessionCoordinator = SessionCoordinator(
      contextProvider: StackPasteTestContextProvider(),
      recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
      transformerRegistry: TextTransformerRegistry(transformers: []),
      actionRegistry: OutputActionRegistry(actions: []),
      candidateResolver: candidateResolver,
      deliveryStack: deliveryStack,
      eventBus: eventBus
    )
    let pasteboard = await MainActor.run {
      PausedWritePasteboard(
        initialSnapshot: ClipboardSnapshot(plainText: "external", changeCount: 1))
    }
    await pasteboard.setPauseNextWrite()

    let controller = StackPasteController(
      hotkeyTap: HotkeyEventTap(),
      pasteboard: pasteboard,
      contextProvider: StackPasteTestContextProvider(),
      deliveryStack: deliveryStack,
      sessionCoordinator: sessionCoordinator,
      eventBus: eventBus,
      privacySettingsProvider: { .defaults },
      focusIdentitySampleProvider: {
        FocusPrivacyIdentitySample(
          focus: makeFocus(),
          applicationActivationRevision: 0
        )
      },
      accessibilityChecker: { false }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    let previewSnapshot = ClipboardSnapshot(plainText: "preview", changeCount: 9)
    let nonEmptySnapshot = ClipboardRouteSnapshot(
      activeGroup: ClipboardGroupSummary(
        group: .defaultGroup,
        count: 1,
        previewText: "preview"
      ),
      count: 1,
      previewText: "preview",
      previewContentKind: .text,
      previewSnapshot: previewSnapshot,
      previewSubject: makeRouteSubject()
    )
    let gate = PasteOperationGate()

    let routeTask = Task {
      await controller.testingHandleRouteSnapshot(nonEmptySnapshot, routeContext: routeContext)
    }
    await pasteboard.waitUntilWriteStarted()

    let suspensionTask = Task {
      await controller.performProgrammaticPaste {
        await gate.hold()
      }
    }
    await gate.waitUntilStarted()
    await pasteboard.resumePausedWrite()
    await routeTask.value
    await gate.release()
    await suspensionTask.value

    let restoredSnapshot = await pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { pasteboard.restoreCallCount }

    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertEqual(restoredSnapshot.plainText, "external")
  }

  func testSensitiveApplicationSkipsPayloadStorageAndEnablesPasteBypass() async {
    let secret = "sensitive-clipboard-payload"
    let focus = makeFocus(applicationName: "Vault", bundleIdentifier: "com.example.vault")
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: secret, changeCount: 10),
      focus: focus,
      privacySettingsProvider: { settings }
    )

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let diagnostics = await fixture.diagnostics.snapshot(
      matching: DiagnosticQuery(subsystem: .clipboard))
    let skipEvents = diagnostics.filter { $0.event == "clipboard.capture.skipped" }

    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, 0)
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(skipEvents.count, 1)
    XCTAssertNil(skipEvents.first?.metadata["bundleID"])
    XCTAssertFalse(
      skipEvents.contains { event in
        event.message.contains(secret)
          || event.metadata.values.contains(where: { $0.contains(secret) })
      })
  }

  func testProtectedPasteboardTypesAreRejectedBeforePayloadRead() async {
    for (index, protection) in ClipboardProtection.allCases.enumerated() {
      let fixture = await makePrivacyFixture(
        snapshot: ClipboardSnapshot(
          plainText: "secret-\(protection.rawValue)",
          changeCount: 20 + index,
          protections: [protection]
        ),
        focus: makeFocus()
      )

      await fixture.controller.testingCaptureExternalClipboardIfNeeded()

      let stored = await fixture.deliveryStack.clipboardSnapshot()
      let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
      let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
      XCTAssertTrue(stored.items.isEmpty, "\(protection)")
      XCTAssertEqual(payloadReadCount, 0, "\(protection)")
      XCTAssertTrue(bypassActive, "\(protection)")
    }
  }

  func testPrivacySettingsFailureFailsClosedWithOneWarning() async {
    struct PolicyLoadFailure: Error {}

    let secret = "must-not-be-read"
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: secret, changeCount: 31),
      focus: makeFocus(),
      privacySettingsProvider: { throw PolicyLoadFailure() }
    )

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let diagnostics = await fixture.diagnostics.snapshot(
      matching: DiagnosticQuery(subsystem: .clipboard))
    let policyWarnings = diagnostics.filter { $0.event == "clipboard.capture.policy-unavailable" }

    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, 0)
    XCTAssertEqual(policyWarnings.count, 1)
    XCTAssertEqual(policyWarnings.first?.level, .warning)
    XCTAssertFalse(
      policyWarnings.contains { event in
        event.message.contains(secret)
          || event.metadata.values.contains(where: { $0.contains(secret) })
      })
  }

  func testOrdinaryClipboardIsReadOnceAndStored() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "ordinary", changeCount: 40),
      focus: makeFocus()
    )

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()

    XCTAssertEqual(stored.items.map(\.text), ["ordinary"])
    XCTAssertEqual(payloadReadCount, 1)
    XCTAssertFalse(bypassActive)
  }

  func testWorkflowBlockedCaptureKeepsHistoryWithoutPublishingGroupEvent() async throws {
    let focus = makeFocus(
      applicationName: "Private Notes", bundleIdentifier: "com.example.private-notes")
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(
          bundleIdentifier: "com.example.private-notes",
          applicationName: "Private Notes",
          blocksClipboardHistory: false,
          blocksWorkflowCapture: true,
          blocksSelectedText: false,
          blocksCloudProcessing: false
        )
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "history only", changeCount: 50),
      focus: focus,
      privacySettingsProvider: { settings }
    )
    let stream = await fixture.eventBus.stream()
    let probe = StackPasteEventProbe()
    let eventTask = Task {
      for await event in stream {
        await probe.append(event)
      }
    }
    defer { eventTask.cancel() }

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    try await Task.sleep(for: .milliseconds(20))

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let events = await probe.snapshot()
    XCTAssertEqual(stored.items.map(\.text), ["history only"])
    XCTAssertTrue(events.contains { if case .clipboardUpdated = $0 { true } else { false } })
    XCTAssertFalse(events.contains { if case .clipboardGroupEvent = $0 { true } else { false } })
  }

  func testPasteboardChangeDuringAuthorizedReadIsRetriedOnNextPoll() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "stale", changeCount: 60),
      focus: makeFocus()
    )
    await fixture.pasteboard.replaceOnNextRead(
      with: ClipboardSnapshot(plainText: "fresh", changeCount: 61)
    )

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    let firstSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    XCTAssertTrue(firstSnapshot.items.isEmpty)

    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    XCTAssertEqual(stored.items.map(\.text), ["fresh"])
    XCTAssertEqual(payloadReadCount, 2)
  }

  func testSensitiveClipboardDisablesActiveStackPasteInterception() async {
    let focus = makeFocus()
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "ordinary", changeCount: 70),
      focus: focus,
      privacySettingsProvider: { settings },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup, count: 1, previewText: "stack item"),
        count: 1,
        previewText: "stack item",
        previewContentKind: .text,
        previewSnapshot: ClipboardSnapshot(plainText: "stack item", changeCount: 0),
        previewSubject: makeRouteSubject()
      ),
      routeContext: routeContext
    )
    XCTAssertTrue(fixture.hotkeyTap.testingIsPasteInterceptEnabled())

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(
        plainText: "password",
        changeCount: 72,
        protections: [.concealed]
      )
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
    XCTAssertTrue(bypassActive)
  }

  func testPausingCaptureRestoresMirroredClipboardAndSkipsExternalPayload() async {
    let secret = "paused-secret-must-not-be-read"
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original system clipboard", changeCount: 80),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup, count: 1, previewText: "queue preview"),
        count: 1,
        previewText: "queue preview",
        previewContentKind: .text,
        previewSnapshot: ClipboardSnapshot(plainText: "queue preview", changeCount: 0),
        previewSubject: makeRouteSubject()
      ),
      routeContext: routeContext
    )
    XCTAssertTrue(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
    let payloadReadsBeforePause = await MainActor.run { fixture.pasteboard.payloadReadCount }

    await fixture.controller.setClipboardCapturePaused(true)

    let restoredSnapshot = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(restoredSnapshot.plainText, "original system clipboard")
    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())

    let writeCallCountAfterPause = await MainActor.run { fixture.pasteboard.writeCallCount }
    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup, count: 1, previewText: "new queue preview"),
        count: 1,
        previewText: "new queue preview",
        previewContentKind: .text,
        previewSnapshot: ClipboardSnapshot(plainText: "new queue preview", changeCount: 0),
        previewSubject: makeRouteSubject()
      ),
      routeContext: routeContext
    )
    let writeCallCountAfterPausedRouteUpdate = await MainActor.run {
      fixture.pasteboard.writeCallCount
    }
    XCTAssertEqual(writeCallCountAfterPausedRouteUpdate, writeCallCountAfterPause)

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: secret, changeCount: 90)
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let controlState = await fixture.controller.testingCaptureControlState()
    let diagnostics = await fixture.diagnostics.snapshot(
      matching: DiagnosticQuery(subsystem: .clipboard))
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, payloadReadsBeforePause)
    XCTAssertTrue(controlState.isPaused)
    XCTAssertFalse(controlState.isIgnoringNext)
    XCTAssertFalse(
      diagnostics.contains { event in
        event.message.contains(secret)
          || event.metadata.values.contains(where: { $0.contains(secret) })
      })
  }

  func testPausingRetriesFailedMirrorRestoreWithoutDroppingArchive() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 91),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )
    await fixture.pasteboard.failNextRestoreAttempts(1)

    await fixture.controller.setClipboardCapturePaused(true)

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 2)
  }

  func testFailedMirrorRestoreRetryNeverOverwritesExternalWinner() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 92),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )
    await fixture.pasteboard.failNextRestoreAttempts(
      1,
      thenExternalSnapshot: ClipboardSnapshot(
        plainText: "external winner",
        changeCount: 500
      )
    )

    await fixture.controller.setClipboardCapturePaused(true)

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "external winner")
    XCTAssertEqual(restoreCallCount, 1)
  }

  func testMirrorArchiveSurvivesFailedRetriesUntilNextRouteLifecycle() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 93),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: routeContext
    )
    await fixture.pasteboard.failNextRestoreAttempts(2)

    await fixture.controller.setClipboardCapturePaused(true)

    var current = await fixture.pasteboard.peekSnapshot()
    var restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "stack preview")
    XCTAssertEqual(restoreCallCount, 2)

    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup,
          count: 0,
          previewText: nil
        ),
        count: 0,
        previewText: nil,
        previewContentKind: nil,
        previewSnapshot: nil
      ),
      routeContext: routeContext
    )

    current = await fixture.pasteboard.peekSnapshot()
    restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 3)
  }

  func testResumingUsesCurrentChangeCountAsBaselineWithoutBackfill() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "before pause", changeCount: 100),
      focus: makeFocus()
    )
    await fixture.controller.setClipboardCapturePaused(true)
    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "copied while paused", changeCount: 101)
    )

    await fixture.controller.setClipboardCapturePaused(false)
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    var stored = await fixture.deliveryStack.clipboardSnapshot()
    var payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    let resumedState = await fixture.controller.testingCaptureControlState()
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, 0)
    XCTAssertFalse(resumedState.isPaused)

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "copied after resume", changeCount: 102)
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    stored = await fixture.deliveryStack.clipboardSnapshot()
    payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    XCTAssertEqual(stored.items.map(\.text), ["copied after resume"])
    XCTAssertEqual(payloadReadCount, 1)
  }

  func testIgnoreNextConsumesOnlyExternalNonOwnedChangeAndKeepsSystemPasteBypass() async {
    let ignoredSecret = "one-time-ignored-secret"
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "baseline", changeCount: 110),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup, count: 1, previewText: "queue preview"),
        count: 1,
        previewText: "queue preview",
        previewContentKind: .text,
        previewSnapshot: ClipboardSnapshot(plainText: "queue preview", changeCount: 0),
        previewSubject: makeRouteSubject()
      ),
      routeContext: routeContext
    )

    let payloadReadsBeforeIgnore = await MainActor.run { fixture.pasteboard.payloadReadCount }
    await fixture.controller.ignoreNextExternalClipboardChange()
    var controlState = await fixture.controller.testingCaptureControlState()
    XCTAssertTrue(controlState.isIgnoringNext)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())

    let ownedDescriptor = await fixture.pasteboard.currentClipboardDescriptor()
    _ = await fixture.pasteboard.writeClipboardSnapshot(
      ClipboardSnapshot(plainText: "owned change", changeCount: 0),
      ifChangeCountIs: ownedDescriptor.changeCount
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    controlState = await fixture.controller.testingCaptureControlState()
    XCTAssertTrue(
      controlState.isIgnoringNext, "Rill-owned changes must not consume the one-time ignore")

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: ignoredSecret, changeCount: 120)
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    var stored = await fixture.deliveryStack.clipboardSnapshot()
    var payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    controlState = await fixture.controller.testingCaptureControlState()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let diagnostics = await fixture.diagnostics.snapshot(
      matching: DiagnosticQuery(subsystem: .clipboard))
    let observedControlStates = await fixture.captureControlProbe.snapshot()
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, payloadReadsBeforeIgnore)
    XCTAssertFalse(controlState.isIgnoringNext)
    XCTAssertTrue(bypassActive)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
    XCTAssertFalse(
      diagnostics.contains { event in
        event.message.contains(ignoredSecret)
          || event.metadata.values.contains(where: { $0.contains(ignoredSecret) })
      })
    XCTAssertEqual(
      observedControlStates.map(\.state),
      [
        .armingIgnoreNextExternalChange,
        .ignoringNextExternalChange,
        .active,
      ]
    )
    XCTAssertEqual(
      observedControlStates.map(\.revision),
      observedControlStates.map(\.revision).sorted()
    )

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "captured after ignore", changeCount: 121)
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    stored = await fixture.deliveryStack.clipboardSnapshot()
    payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    XCTAssertEqual(stored.items.map(\.text), ["captured after ignore"])
    XCTAssertEqual(payloadReadCount, payloadReadsBeforeIgnore + 1)
  }

  func testPauseWaitsForInFlightPayloadReadAndDiscardsItsResult() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "in-flight secret", changeCount: 130),
      focus: makeFocus()
    )
    await fixture.pasteboard.setPauseNextPayloadRead()

    let captureTask = Task {
      await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    }
    await fixture.pasteboard.waitUntilPayloadReadStarted()
    let pauseTask = Task {
      await fixture.controller.setClipboardCapturePaused(true)
    }
    await fixture.captureControlProbe.waitUntilObserved(.pausing)

    let transitionalSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(transitionalSnapshot.state, .pausing)

    await fixture.pasteboard.resumePausedPayloadRead()
    await captureTask.value
    await pauseTask.value

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let finalSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    let payloadReadCount = await MainActor.run { fixture.pasteboard.payloadReadCount }
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(payloadReadCount, 1)
    XCTAssertEqual(finalSnapshot.state, .paused)
  }

  func testStopRestoresCommittedMirrorBeforeReturning() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 135),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: routeContext
    )
    let mirrored = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(mirrored.plainText, "stack preview")

    await fixture.controller.stop()

    let restored = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    let controlSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(restored.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertEqual(controlSnapshot.state, .paused)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
  }

  func testStopDrainsRepeatedMirrorRestoreFailuresBeforeReturning() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 137),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )
    await fixture.pasteboard.failNextRestoreAttempts(3)

    await fixture.controller.stop()

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 4)
  }

  func testStopFailedRestoreRetryAcceptsExternalWinnerWithoutOverwrite() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 138),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )
    await fixture.pasteboard.failNextRestoreAttempts(
      1,
      thenExternalSnapshot: ClipboardSnapshot(
        plainText: "external winner",
        changeCount: 600
      )
    )

    await fixture.controller.stop()

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "external winner")
    XCTAssertEqual(restoreCallCount, 1)
  }

  func testStopWaitsForInFlightCaptureAndDiscardsItsResult() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "in-flight clipboard", changeCount: 136),
      focus: makeFocus()
    )
    await fixture.pasteboard.setPauseNextPayloadRead()

    let captureTask = Task {
      await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    }
    await fixture.pasteboard.waitUntilPayloadReadStarted()
    let stopTask = Task {
      await fixture.controller.stop()
    }
    let didBeginStopping = await waitForCaptureControlState(
      .pausing,
      controller: fixture.controller
    )
    XCTAssertTrue(didBeginStopping)

    await fixture.pasteboard.resumePausedPayloadRead()
    await captureTask.value
    await stopTask.value

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let current = await fixture.pasteboard.peekSnapshot()
    let controlSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertEqual(current.plainText, "in-flight clipboard")
    XCTAssertEqual(controlSnapshot.state, .paused)
  }

  func testStopWaitsForPendingMirrorAndRestoresOriginalClipboard() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 137),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.pasteboard.setPauseNextWrite()
    let mirrorTask = Task {
      await fixture.controller.testingHandleRouteSnapshot(
        makeRouteSnapshot(previewText: "pending preview"),
        routeContext: routeContext
      )
    }
    await fixture.pasteboard.waitUntilWriteStarted()
    let stopTask = Task {
      await fixture.controller.stop()
    }
    let didBeginStopping = await waitForCaptureControlState(
      .pausing,
      controller: fixture.controller
    )
    XCTAssertTrue(didBeginStopping)
    let repeatedStopCompletion = AsyncCompletionProbe()
    let repeatedStopTask = Task {
      await fixture.controller.stop()
      await repeatedStopCompletion.markCompleted()
    }
    try? await Task.sleep(for: .milliseconds(10))
    let repeatedStopReturnedEarly = await repeatedStopCompletion.isCompleted()
    XCTAssertFalse(repeatedStopReturnedEarly)
    let pending = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(pending.plainText, "pending preview")

    await fixture.pasteboard.resumePausedWrite()
    await mirrorTask.value
    await stopTask.value
    await repeatedStopTask.value

    let restored = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    let repeatedStopCompleted = await repeatedStopCompletion.isCompleted()
    XCTAssertEqual(restored.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertTrue(repeatedStopCompleted)
  }

  func testStopNeverRestoresOverExternalClipboardChangeWhileMirrorSettles() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 138),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.pasteboard.setPauseNextWrite()
    let mirrorTask = Task {
      await fixture.controller.testingHandleRouteSnapshot(
        makeRouteSnapshot(previewText: "pending preview"),
        routeContext: routeContext
      )
    }
    await fixture.pasteboard.waitUntilWriteStarted()
    let stopTask = Task {
      await fixture.controller.stop()
    }
    let didBeginStopping = await waitForCaptureControlState(
      .pausing,
      controller: fixture.controller
    )
    XCTAssertTrue(didBeginStopping)

    await fixture.pasteboard.setExternalSnapshot(
      ClipboardSnapshot(plainText: "external winner", changeCount: 140)
    )
    await fixture.pasteboard.resumePausedWrite()
    await mirrorTask.value
    await stopTask.value

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "external winner")
    XCTAssertEqual(restoreCallCount, 0)
  }

  func testPauseDuringPendingMirrorWriteRestoresOriginalClipboardBeforeCompleting() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 140),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    let routeSnapshot = ClipboardRouteSnapshot(
      activeGroup: ClipboardGroupSummary(
        group: .defaultGroup, count: 1, previewText: "pending preview"),
      count: 1,
      previewText: "pending preview",
      previewContentKind: .text,
      previewSnapshot: ClipboardSnapshot(plainText: "pending preview", changeCount: 0),
      previewSubject: makeRouteSubject()
    )
    await fixture.pasteboard.setPauseNextWrite()

    let mirrorTask = Task {
      await fixture.controller.testingHandleRouteSnapshot(routeSnapshot, routeContext: routeContext)
    }
    await fixture.pasteboard.waitUntilWriteStarted()
    let pauseTask = Task {
      await fixture.controller.setClipboardCapturePaused(true)
    }
    await fixture.captureControlProbe.waitUntilObserved(.pausing)

    await fixture.pasteboard.resumePausedWrite()
    await mirrorTask.value
    await pauseTask.value

    let current = await fixture.pasteboard.peekSnapshot()
    let finalSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertEqual(finalSnapshot.state, .paused)
  }

  func testIgnoreNextDuringPendingMirrorWriteRestoresOriginalClipboardBeforeArming() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 150),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    let routeSnapshot = ClipboardRouteSnapshot(
      activeGroup: ClipboardGroupSummary(
        group: .defaultGroup, count: 1, previewText: "pending preview"),
      count: 1,
      previewText: "pending preview",
      previewContentKind: .text,
      previewSnapshot: ClipboardSnapshot(plainText: "pending preview", changeCount: 0),
      previewSubject: makeRouteSubject()
    )
    await fixture.pasteboard.setPauseNextWrite()

    let mirrorTask = Task {
      await fixture.controller.testingHandleRouteSnapshot(routeSnapshot, routeContext: routeContext)
    }
    await fixture.pasteboard.waitUntilWriteStarted()
    let ignoreTask = Task {
      await fixture.controller.ignoreNextExternalClipboardChange()
    }
    await fixture.captureControlProbe.waitUntilObserved(.armingIgnoreNextExternalChange)

    await fixture.pasteboard.resumePausedWrite()
    await mirrorTask.value
    await ignoreTask.value

    let current = await fixture.pasteboard.peekSnapshot()
    let finalSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertEqual(finalSnapshot.state, .ignoringNextExternalChange)
  }

  func testPauseInvalidatesResumeWhileDescriptorReadIsSuspended() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "resume baseline", changeCount: 160),
      focus: makeFocus()
    )
    await fixture.controller.setClipboardCapturePaused(true)
    await fixture.pasteboard.setPauseNextDescriptorRead()

    let resumeTask = Task {
      await fixture.controller.setClipboardCapturePaused(false)
    }
    await fixture.pasteboard.waitUntilDescriptorReadStarted()
    let resumingSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(resumingSnapshot.state, .resuming)

    await fixture.controller.setClipboardCapturePaused(true)
    let pausedSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(pausedSnapshot.state, .paused)

    await fixture.pasteboard.resumePausedDescriptorRead()
    await resumeTask.value
    let finalSnapshot = await fixture.controller.testingCaptureControlSnapshot()
    XCTAssertEqual(finalSnapshot.state, .paused)
  }

  func testFocusActivationDuringPayloadReadFailsClosedBeforeDelivery() async {
    let initialFocus = makeFocus(applicationName: "Notes", bundleIdentifier: "com.apple.Notes")
    let focusProbe = FocusIdentitySampleProbe(
      sample: FocusPrivacyIdentitySample(
        focus: initialFocus,
        applicationActivationRevision: 1
      )
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "focus-race secret", changeCount: 170),
      focus: initialFocus,
      focusIdentitySampleProvider: { await focusProbe.current() }
    )
    await fixture.pasteboard.setPauseNextPayloadRead()

    let captureTask = Task {
      await fixture.controller.testingCaptureExternalClipboardIfNeeded()
    }
    await fixture.pasteboard.waitUntilPayloadReadStarted()
    await focusProbe.update(
      FocusPrivacyIdentitySample(
        focus: makeFocus(applicationName: "Vault", bundleIdentifier: "com.example.vault"),
        applicationActivationRevision: 2
      )
    )
    await fixture.pasteboard.resumePausedPayloadRead()
    await captureTask.value

    let stored = await fixture.deliveryStack.clipboardSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let diagnostics = await fixture.diagnostics.snapshot(
      matching: DiagnosticQuery(subsystem: .clipboard))
    XCTAssertTrue(stored.items.isEmpty)
    XCTAssertTrue(bypassActive)
    XCTAssertTrue(diagnostics.contains { $0.event == "clipboard.capture.focus-transition-skipped" })
  }

  func testSwitchingToSensitiveApplicationRestoresMirrorWithoutClipboardChange() async {
    let initialFocus = makeFocus()
    let focusProbe = FocusIdentitySampleProbe(
      sample: FocusPrivacyIdentitySample(
        focus: initialFocus,
        applicationActivationRevision: 1
      )
    )
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 180),
      focus: initialFocus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      privacySettingsProvider: { settings },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let routeSnapshot = makeRouteSnapshot(previewText: "stack preview")

    await fixture.controller.testingHandleRouteSnapshot(routeSnapshot, routeContext: routeContext)
    let mirrored = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(mirrored.plainText, "stack preview")

    await focusProbe.update(
      FocusPrivacyIdentitySample(
        focus: makeFocus(applicationName: "Vault", bundleIdentifier: "com.example.vault"),
        applicationActivationRevision: 2
      )
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let current = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(restoreCallCount, 1)
    XCTAssertFalse(fixture.hotkeyTap.testingIsPasteInterceptEnabled())
  }

  func testSecureInputChangeInSameApplicationRestoresMirrorWithoutClipboardChange() async {
    let initialFocus = makeFocus()
    let focusProbe = FocusIdentitySampleProbe(
      sample: FocusPrivacyIdentitySample(
        focus: initialFocus,
        applicationActivationRevision: 1
      )
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 190),
      focus: initialFocus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )

    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: routeContext
    )
    let mirrored = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(mirrored.plainText, "stack preview")

    await focusProbe.update(
      FocusPrivacyIdentitySample(
        focus: makeFocus(secureInput: true),
        applicationActivationRevision: 1
      )
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let current = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(restoreCallCount, 1)
  }

  func testPrivacySettingsTighteningRestoresMirrorWithoutClipboardChange() async {
    let focus = makeFocus()
    let settingsProbe = PrivacySettingsProbe(settings: .defaults)
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 200),
      focus: focus,
      privacySettingsProvider: { await settingsProbe.current() },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )

    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stack preview"),
      routeContext: routeContext
    )
    let mirrored = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(mirrored.plainText, "stack preview")

    await settingsProbe.update(
      PrivacyPolicySettings(
        sensitiveAppRules: [
          SensitiveAppRule(
            bundleIdentifier: "com.apple.Notes",
            applicationName: "Notes"
          )
        ],
        cloudConfirmationRequired: false
      )
    )
    await fixture.controller.testingCaptureExternalClipboardIfNeeded()

    let current = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(restoreCallCount, 1)
  }

  func testExternalClipboardChangeBeforeConditionalMirrorWriteIsNeverOverwritten() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "authorized baseline", changeCount: 205),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.pasteboard.replaceBeforeNextWrite(
      with: ClipboardSnapshot(plainText: "external winner", changeCount: 206)
    )

    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stale preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    XCTAssertEqual(current.plainText, "external winner")
    XCTAssertEqual(restoreCallCount, 0)
    XCTAssertTrue(bypassActive)
  }

  func testProtectedClipboardChangeBeforeConditionalMirrorWriteIsNeverOverwritten() async {
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "authorized baseline", changeCount: 207),
      focus: makeFocus(),
      accessibilityChecker: { true }
    )
    await fixture.pasteboard.replaceBeforeNextWrite(
      with: ClipboardSnapshot(
        plainText: "protected winner",
        changeCount: 208,
        protections: [.concealed]
      )
    )

    await fixture.controller.testingHandleRouteSnapshot(
      makeRouteSnapshot(previewText: "stale preview"),
      routeContext: ClipboardRouteContext(
        applicationName: "Notes",
        bundleIdentifier: "com.apple.Notes"
      )
    )

    let current = await fixture.pasteboard.peekSnapshot()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "protected winner")
    XCTAssertEqual(current.protections, [.concealed])
    XCTAssertEqual(restoreCallCount, 0)
  }

  func testFocusChangeDuringMirrorWriteRestoresOriginalAndDoesNotCommitMirror() async {
    let initialFocus = makeFocus()
    let focusProbe = FocusIdentitySampleProbe(
      sample: FocusPrivacyIdentitySample(
        focus: initialFocus,
        applicationActivationRevision: 1
      )
    )
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 210),
      focus: initialFocus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      privacySettingsProvider: { settings },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.pasteboard.setPauseNextWrite()

    let mirrorTask = Task {
      await fixture.controller.testingHandleRouteSnapshot(
        makeRouteSnapshot(previewText: "pending preview"),
        routeContext: routeContext
      )
    }
    await fixture.pasteboard.waitUntilWriteStarted()
    await focusProbe.update(
      FocusPrivacyIdentitySample(
        focus: makeFocus(applicationName: "Vault", bundleIdentifier: "com.example.vault"),
        applicationActivationRevision: 2
      )
    )
    await fixture.pasteboard.resumePausedWrite()
    await mirrorTask.value

    let current = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    let restoreCallCount = await MainActor.run { fixture.pasteboard.restoreCallCount }
    XCTAssertEqual(current.plainText, "original clipboard")
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(restoreCallCount, 1)
  }

  func testSensitiveFocusPreventsMirroringBeforeSystemPasteBypass() async {
    let focus = makeFocus(applicationName: "Vault", bundleIdentifier: "com.example.vault")
    let settings = PrivacyPolicySettings(
      sensitiveAppRules: [
        SensitiveAppRule(bundleIdentifier: "com.example.vault", applicationName: "Vault")
      ],
      cloudConfirmationRequired: false
    )
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 180),
      focus: focus,
      privacySettingsProvider: { settings },
      accessibilityChecker: { true }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Vault", bundleIdentifier: "com.example.vault")
    await fixture.controller.testingHandleRouteSnapshot(
      ClipboardRouteSnapshot(
        activeGroup: ClipboardGroupSummary(
          group: .defaultGroup, count: 1, previewText: "stack preview"),
        count: 1,
        previewText: "stack preview",
        previewContentKind: .text,
        previewSnapshot: ClipboardSnapshot(plainText: "stack preview", changeCount: 0),
        previewSubject: makeRouteSubject()
      ),
      routeContext: routeContext
    )
    let current = await fixture.pasteboard.peekSnapshot()
    XCTAssertEqual(current.plainText, "original clipboard")

    let shouldBypass = await fixture.controller.testingShouldBypassPasteInterception()

    let restored = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    XCTAssertTrue(shouldBypass)
    XCTAssertTrue(bypassActive)
    XCTAssertEqual(restored.plainText, "original clipboard")
  }

  func testEmptyRouteDoesNotSendFailOrConsume() async throws {
    let pasteProbe = StackPasteCommandProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 215),
      focus: makeFocus(),
      accessibilityChecker: { true },
      pasteCommandSender: { await pasteProbe.send() }
    )
    let stream = await fixture.eventBus.stream()
    let eventProbe = StackPasteEventProbe()
    let eventTask = Task {
      for await event in stream {
        await eventProbe.append(event)
      }
    }
    defer { eventTask.cancel() }

    await fixture.controller.pasteTopOfStack()
    try await Task.sleep(for: .milliseconds(20))

    let pasteSendCount = await pasteProbe.snapshot()
    let stackSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    let events = await eventProbe.snapshot()
    XCTAssertEqual(pasteSendCount, 0)
    XCTAssertTrue(stackSnapshot.items.isEmpty)
    XCTAssertFalse(
      events.contains { event in
        if case .runFailed = event { return true }
        return false
      })
  }

  func testConcurrentPasteEntrancesReserveDeliveryBeforeResolvingRouteContext() async {
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let routeContextGate = ActiveRouteContextGate(routeContext: routeContext)
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 216),
      focus: makeFocus(),
      activeRouteContextProvider: { await routeContextGate.resolve() },
      accessibilityChecker: { true }
    )

    let firstPaste = Task {
      await fixture.controller.pasteTopOfStack()
    }
    await routeContextGate.waitUntilFirstRequestStarts()
    let secondPaste = Task {
      await fixture.controller.pasteTopOfStack()
    }
    await secondPaste.value

    let routeContextRequestCount = await routeContextGate.requests()
    XCTAssertEqual(routeContextRequestCount, 1)

    await routeContextGate.releaseFirstRequest()
    await firstPaste.value
  }

  func testStopWaitsForProgrammaticDeliveryAndRejectsPostStopEntrance() async {
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    let routeContextGate = ActiveRouteContextGate(routeContext: routeContext)
    let completionProbe = AsyncCompletionProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 217),
      focus: makeFocus(),
      activeRouteContextProvider: { await routeContextGate.resolve() },
      accessibilityChecker: { true }
    )

    let pasteTask = Task {
      await fixture.controller.pasteTopOfStack()
    }
    await routeContextGate.waitUntilFirstRequestStarts()
    let stopTask = Task {
      await fixture.controller.stop()
      await completionProbe.markCompleted()
    }
    let didBeginStopping = await waitForCaptureControlState(
      .pausing,
      controller: fixture.controller
    )
    XCTAssertTrue(didBeginStopping)
    try? await Task.sleep(for: .milliseconds(10))
    let completedWhileDeliveryWasSuspended = await completionProbe.isCompleted()
    XCTAssertFalse(completedWhileDeliveryWasSuspended)

    await routeContextGate.releaseFirstRequest()
    await pasteTask.value
    await stopTask.value
    let completedAfterDelivery = await completionProbe.isCompleted()
    XCTAssertTrue(completedAfterDelivery)

    let requestsBeforePostStopPaste = await routeContextGate.requests()
    await fixture.controller.pasteTopOfStack()
    let requestsAfterPostStopPaste = await routeContextGate.requests()
    XCTAssertEqual(requestsAfterPostStopPaste, requestsBeforePostStopPaste)
  }

  func testStopWaitsForNestedProgrammaticPasteAndRejectsPostStopEntrance() async {
    let innerGate = PasteOperationGate()
    let outerGate = PasteOperationGate()
    let stopCompletion = AsyncCompletionProbe()
    let rejectedOperation = AsyncCompletionProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 218),
      focus: makeFocus()
    )
    let controller = fixture.controller

    let pasteTask = Task {
      await controller.performProgrammaticPaste {
        await controller.performProgrammaticPaste {
          await innerGate.hold()
        }
        await outerGate.hold()
      }
    }
    await innerGate.waitUntilStarted()

    let stopTask = Task {
      await controller.stop()
      await stopCompletion.markCompleted()
    }
    let didBeginStopping = await waitForCaptureControlState(
      .pausing,
      controller: controller
    )
    XCTAssertTrue(didBeginStopping)

    await controller.performProgrammaticPaste {
      await rejectedOperation.markCompleted()
    }
    let postStopOperationExecuted = await rejectedOperation.isCompleted()
    XCTAssertFalse(postStopOperationExecuted)

    await innerGate.release()
    await outerGate.waitUntilStarted()
    try? await Task.sleep(for: .milliseconds(10))
    let completedBeforeOuterSession = await stopCompletion.isCompleted()
    XCTAssertFalse(completedBeforeOuterSession)

    await outerGate.release()
    await pasteTask.value
    await stopTask.value

    let completedAfterAllSessions = await stopCompletion.isCompleted()
    let operationCounts = await controller.testingProgrammaticPasteOperationCounts()
    XCTAssertTrue(completedAfterAllSessions)
    XCTAssertEqual(operationCounts.active, 0)
    XCTAssertEqual(operationCounts.inFlight, 0)
  }

  func testCancelledProgrammaticPasteReleasesSessionOwnership() async {
    let operationProbe = CancellablePasteOperationProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "system clipboard", changeCount: 219),
      focus: makeFocus()
    )
    let controller = fixture.controller

    let pasteTask = Task {
      await controller.performProgrammaticPaste {
        await operationProbe.runUntilCancelled()
      }
    }
    await operationProbe.waitUntilStarted()
    pasteTask.cancel()
    await pasteTask.value

    let operationCounts = await controller.testingProgrammaticPasteOperationCounts()
    XCTAssertEqual(operationCounts.active, 0)
    XCTAssertEqual(operationCounts.inFlight, 0)
    await controller.stop()
  }

  func testImagePasteFocusDriftDoesNotSendOrConsumeLease() async throws {
    let initialSample = FocusPrivacyIdentitySample(
      focus: makeFocus(),
      applicationActivationRevision: 1
    )
    let driftedSample = FocusPrivacyIdentitySample(
      focus: makeFocus(
        applicationName: "Vault",
        bundleIdentifier: "com.example.vault"
      ),
      applicationActivationRevision: 2
    )
    let focusProbe = FocusIdentitySampleProbe(sample: initialSample)
    let pasteProbe = StackPasteCommandProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 220),
      focus: initialSample.focus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      accessibilityChecker: { true },
      pasteCommandSender: { await pasteProbe.send() }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(
        plainText: "",
        imagePNGData: Data([0x89, 0x50, 0x4E, 0x47]),
        changeCount: 0
      ),
      context: routeContext,
      disposition: .historyAndWorkflows
    )
    let routeSnapshot = await fixture.deliveryStack.routeSnapshot(for: routeContext)
    XCTAssertEqual(routeSnapshot.previewContentKind, .image)
    await fixture.controller.testingHandleRouteSnapshot(
      routeSnapshot,
      routeContext: routeContext
    )
    await focusProbe.enqueue([
      initialSample,
      initialSample,
      driftedSample,
    ])

    await fixture.controller.testingPasteMirroredClipboardItem(for: routeContext)

    let pasteSendCount = await pasteProbe.snapshot()
    let stackSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    let item = try XCTUnwrap(stackSnapshot.items.first)
    let currentClipboard = await fixture.pasteboard.peekSnapshot()
    let bypassActive = await fixture.controller.testingPrivacyPasteBypassActive()
    XCTAssertEqual(pasteSendCount, 0)
    XCTAssertEqual(item.useCount, 0)
    XCTAssertTrue(stackSnapshot.remainingItemIDs.contains(item.id))
    XCTAssertEqual(currentClipboard.plainText, "original clipboard")
    XCTAssertTrue(bypassActive)
  }

  func testFileHistoryItemNeverEntersStackRouteOrConsumesOnFocusDrift() async throws {
    let initialSample = FocusPrivacyIdentitySample(
      focus: makeFocus(),
      applicationActivationRevision: 1
    )
    let driftedSample = FocusPrivacyIdentitySample(
      focus: makeFocus(
        applicationName: "Finder",
        bundleIdentifier: "com.apple.finder"
      ),
      applicationActivationRevision: 2
    )
    let focusProbe = FocusIdentitySampleProbe(sample: initialSample)
    let pasteProbe = StackPasteCommandProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 230),
      focus: initialSample.focus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      accessibilityChecker: { true },
      pasteCommandSender: { await pasteProbe.send() }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(
        plainText: "",
        fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
        changeCount: 0
      ),
      context: routeContext,
      disposition: .historyAndWorkflows
    )
    let routeSnapshot = await fixture.deliveryStack.routeSnapshot(for: routeContext)
    XCTAssertEqual(routeSnapshot.count, 0)
    XCTAssertNil(routeSnapshot.previewContentKind)
    await focusProbe.update(driftedSample)
    await fixture.controller.pasteTopOfStack()

    let pasteSendCount = await pasteProbe.snapshot()
    let stackSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    let item = try XCTUnwrap(stackSnapshot.items.first)
    XCTAssertEqual(pasteSendCount, 0)
    XCTAssertEqual(item.useCount, 0)
    XCTAssertFalse(stackSnapshot.remainingItemIDs.contains(item.id))
  }

  func testSuccessfulRichPasteCommitsOnceWhenFocusChangesAfterSend() async throws {
    let initialSample = FocusPrivacyIdentitySample(
      focus: makeFocus(),
      applicationActivationRevision: 1
    )
    let driftedSample = FocusPrivacyIdentitySample(
      focus: makeFocus(
        applicationName: "Finder",
        bundleIdentifier: "com.apple.finder"
      ),
      applicationActivationRevision: 2
    )
    let focusProbe = FocusIdentitySampleProbe(sample: initialSample)
    let pasteProbe = StackPasteCommandProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 250),
      focus: initialSample.focus,
      focusIdentitySampleProvider: { await focusProbe.current() },
      accessibilityChecker: { true },
      pasteCommandSender: {
        let sent = await pasteProbe.send()
        await focusProbe.update(driftedSample)
        return sent
      }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(
        plainText: "",
        imagePNGData: Data([0x89, 0x50, 0x4E, 0x47]),
        changeCount: 0
      ),
      context: routeContext,
      disposition: .historyAndWorkflows
    )
    let routeSnapshot = await fixture.deliveryStack.routeSnapshot(for: routeContext)
    await fixture.controller.testingHandleRouteSnapshot(
      routeSnapshot,
      routeContext: routeContext
    )

    await fixture.controller.testingPasteMirroredClipboardItem(for: routeContext)
    await fixture.controller.testingPasteMirroredClipboardItem(for: routeContext)

    let pasteSendCount = await pasteProbe.snapshot()
    let stackSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    let item = try XCTUnwrap(stackSnapshot.items.first)
    XCTAssertEqual(pasteSendCount, 1)
    XCTAssertEqual(item.useCount, 1)
    XCTAssertFalse(stackSnapshot.remainingItemIDs.contains(item.id))
  }

  func testRichPasteConsumesTheExactMirroredItemWhenANewerCandidateArrives() async throws {
    let pasteProbe = StackPasteCommandProbe()
    let fixture = await makePrivacyFixture(
      snapshot: ClipboardSnapshot(plainText: "original clipboard", changeCount: 260),
      focus: makeFocus(),
      accessibilityChecker: { true },
      pasteCommandSender: { await pasteProbe.send() }
    )
    let routeContext = ClipboardRouteContext(
      applicationName: "Notes",
      bundleIdentifier: "com.apple.Notes"
    )
    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(
        plainText: "",
        imagePNGData: Data([0x01]),
        changeCount: 0
      ),
      context: routeContext,
      disposition: .historyAndWorkflows
    )
    let mirroredRoute = await fixture.deliveryStack.routeSnapshot(for: routeContext)
    let mirroredSubject = try XCTUnwrap(mirroredRoute.previewSubject)
    await fixture.controller.testingHandleRouteSnapshot(
      mirroredRoute,
      routeContext: routeContext
    )

    await fixture.deliveryStack.captureSystemClipboard(
      snapshot: ClipboardSnapshot(
        plainText: "",
        imagePNGData: Data([0x02]),
        changeCount: 0
      ),
      context: routeContext,
      disposition: .historyAndWorkflows
    )
    let newerRoute = await fixture.deliveryStack.routeSnapshot(for: routeContext)
    let newerSubject = try XCTUnwrap(newerRoute.previewSubject)
    XCTAssertNotEqual(newerSubject.itemID, mirroredSubject.itemID)

    await fixture.controller.testingPasteMirroredClipboardItem(for: routeContext)

    let pasteSendCount = await pasteProbe.snapshot()
    let stackSnapshot = await fixture.deliveryStack.clipboardSnapshot()
    let mirroredItem = try XCTUnwrap(
      stackSnapshot.items.first { $0.id == mirroredSubject.itemID }
    )
    let newerItem = try XCTUnwrap(
      stackSnapshot.items.first { $0.id == newerSubject.itemID }
    )
    XCTAssertEqual(pasteSendCount, 1)
    XCTAssertEqual(mirroredItem.useCount, 1)
    XCTAssertEqual(newerItem.useCount, 0)
    XCTAssertFalse(stackSnapshot.remainingItemIDs.contains(mirroredItem.id))
    XCTAssertTrue(stackSnapshot.remainingItemIDs.contains(newerItem.id))
  }
}

private struct PrivacyFixture {
  let controller: StackPasteController
  let pasteboard: PrivacyTestPasteboard
  let deliveryStack: DeliveryStack
  let eventBus: EventBus
  let diagnostics: DiagnosticsRecorder
  let hotkeyTap: HotkeyEventTap
  let captureControlProbe: ClipboardCaptureControlProbe
}

private final class GlobalInputLifecycleProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var installOutcomes: [Bool]
  private var installInvocationCount = 0
  private var uninstallInvocationCount = 0
  private var observedCapabilities: [GlobalInputCapability] = []

  init(installOutcomes: [Bool]) {
    self.installOutcomes = installOutcomes
  }

  func install() -> Bool {
    lock.withLock {
      installInvocationCount += 1
      guard !installOutcomes.isEmpty else { return false }
      return installOutcomes.removeFirst()
    }
  }

  func recordUninstall() {
    lock.withLock {
      uninstallInvocationCount += 1
    }
  }

  func record(_ capability: GlobalInputCapability) {
    lock.withLock {
      observedCapabilities.append(capability)
    }
  }

  var installCount: Int {
    lock.withLock { installInvocationCount }
  }

  var uninstallCount: Int {
    lock.withLock { uninstallInvocationCount }
  }

  var capabilities: [GlobalInputCapability] {
    lock.withLock { observedCapabilities }
  }
}

private func makePrivacyFixture(
  snapshot: ClipboardSnapshot,
  focus: FocusSnapshot,
  focusIdentitySampleProvider: (@Sendable () async -> FocusPrivacyIdentitySample)? = nil,
  activeRouteContextProvider: (@Sendable () async -> ClipboardRouteContext)? = nil,
  privacySettingsProvider: @escaping @Sendable () async throws -> PrivacyPolicySettings = {
    .defaults
  },
  accessibilityChecker: @escaping @Sendable () -> Bool = { false },
  hotkeyTap suppliedHotkeyTap: HotkeyEventTap? = nil,
  pasteCommandSender: @escaping @Sendable () async -> Bool = { true }
) async -> PrivacyFixture {
  let eventBus = EventBus()
  let diagnostics = DiagnosticsRecorder(eventBus: eventBus)
  let deliveryStack = DeliveryStack(eventBus: eventBus, diagnostics: diagnostics)
  let coordinator = SessionCoordinator(
    contextProvider: StackPasteTestContextProvider(),
    recognizerRegistry: SpeechRecognizerRegistry(recognizers: []),
    transformerRegistry: TextTransformerRegistry(transformers: []),
    actionRegistry: OutputActionRegistry(actions: []),
    candidateResolver: CandidateResolver(eventBus: eventBus, diagnostics: diagnostics),
    deliveryStack: deliveryStack,
    eventBus: eventBus,
    diagnostics: diagnostics
  )
  let pasteboard = await MainActor.run { PrivacyTestPasteboard(snapshot: snapshot) }
  let hotkeyTap = suppliedHotkeyTap ?? HotkeyEventTap()
  let captureControlProbe = ClipboardCaptureControlProbe()
  let controller = StackPasteController(
    hotkeyTap: hotkeyTap,
    pasteboard: pasteboard,
    contextProvider: StackPasteTestContextProvider(),
    deliveryStack: deliveryStack,
    sessionCoordinator: coordinator,
    eventBus: eventBus,
    diagnostics: diagnostics,
    privacySettingsProvider: privacySettingsProvider,
    focusIdentitySampleProvider: focusIdentitySampleProvider ?? {
      FocusPrivacyIdentitySample(
        focus: focus,
        applicationActivationRevision: 0
      )
    },
    activeRouteContextProvider: activeRouteContextProvider,
    captureControlStateObserver: { snapshot in
      await captureControlProbe.append(snapshot)
    },
    accessibilityChecker: accessibilityChecker,
    pasteCommandSender: pasteCommandSender
  )
  return PrivacyFixture(
    controller: controller,
    pasteboard: pasteboard,
    deliveryStack: deliveryStack,
    eventBus: eventBus,
    diagnostics: diagnostics,
    hotkeyTap: hotkeyTap,
    captureControlProbe: captureControlProbe
  )
}

private func waitForCaptureControlState(
  _ expectedState: ClipboardCaptureControlState,
  controller: StackPasteController
) async -> Bool {
  for _ in 0..<100 {
    if await controller.testingCaptureControlSnapshot().state == expectedState {
      return true
    }
    await Task.yield()
  }
  return false
}

private func makeFocus(
  applicationName: String = "Notes",
  bundleIdentifier: String = "com.apple.Notes",
  secureInput: Bool = false
) -> FocusSnapshot {
  FocusSnapshot(
    applicationName: applicationName,
    bundleIdentifier: bundleIdentifier,
    processIdentifier: nil,
    focusedRole: nil,
    selectedText: "",
    secureInput: secureInput
  )
}

private func makeRouteSnapshot(previewText: String) -> ClipboardRouteSnapshot {
  ClipboardRouteSnapshot(
    activeGroup: ClipboardGroupSummary(
      group: .defaultGroup,
      count: 1,
      previewText: previewText
    ),
    count: 1,
    previewText: previewText,
    previewContentKind: .text,
    previewSnapshot: ClipboardSnapshot(plainText: previewText, changeCount: 0),
    previewSubject: makeRouteSubject()
  )
}

private func makeRouteSubject(
  contentKind: ClipboardContentKind = .text
) -> ClipboardItemDryRunSubject {
  ClipboardItemDryRunSubject(
    itemID: UUID(),
    itemVersion: ClipboardItemVersion(),
    groupID: ClipboardGroup.defaultGroupID,
    contentKind: contentKind,
    hasTransferableContent: true
  )
}
