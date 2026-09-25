import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

private actor CancellationIgnoringSpeechProvider {
  private var prepareCallCount = 0
  private var receivedSettings: LocalSpeechSettings?
  private var didStart = false
  private var didObserveCancellation = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
  private var completion: CheckedContinuation<String, Never>?
  private var progressCallback: (@Sendable (Progress) -> Void)?

  func prepare(
    settings: LocalSpeechSettings? = nil,
    progressCallback: (@Sendable (Progress) -> Void)? = nil
  ) async -> String {
    prepareCallCount += 1
    receivedSettings = settings
    self.progressCallback = progressCallback
    didStart = true
    let pendingStartWaiters = startWaiters
    startWaiters.removeAll()
    for waiter in pendingStartWaiters {
      waiter.resume()
    }

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        completion = continuation
      }
    } onCancel: {
      Task { await self.recordCancellation() }
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func callCount() -> Int {
    prepareCallCount
  }

  func settingsSnapshot() -> LocalSpeechSettings? {
    receivedSettings
  }

  func waitUntilCancellationObserved() async {
    guard !didObserveCancellation else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters.append(continuation)
    }
  }

  func emitProgress(completed: Int64, total: Int64) {
    let progress = Progress(totalUnitCount: total)
    progress.completedUnitCount = completed
    progressCallback?(progress)
  }

  func release(returning modelIdentifier: String) {
    completion?.resume(returning: modelIdentifier)
    completion = nil
  }

  private func recordCancellation() {
    guard !didObserveCancellation else { return }
    didObserveCancellation = true
    let waiters = cancellationWaiters
    cancellationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor CancellationIgnoringSpeechProviderQueue {
  private let providers: [CancellationIgnoringSpeechProvider]
  private var nextProviderIndex = 0

  init(_ providers: [CancellationIgnoringSpeechProvider]) {
    self.providers = providers
  }

  func prepare(
    settings: LocalSpeechSettings? = nil,
    progressCallback: (@Sendable (Progress) -> Void)? = nil
  ) async -> String {
    let provider = providers[nextProviderIndex]
    nextProviderIndex += 1
    return await provider.prepare(settings: settings, progressCallback: progressCallback)
  }
}

private actor SpeechShutdownCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}

@MainActor
final class AppModelLocalSpeechPreparationShutdownTests: XCTestCase {

  func testUserCancelBeforeScheduledPreparationDoesNotStartProvider() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringSpeechProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.prepareLocalSpeechModel()
    harness.model.voice.cancelLocalSpeechModelPreparation()
    for _ in 0..<20 {
      await Task.yield()
    }

    let callCount = await provider.callCount()
    XCTAssertEqual(callCount, 0)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
    await harness.model.drainAndStopEventListenerForApplicationShutdown()
  }

  func testUserCancelReturnsToIdleAndRejectsCancellationIgnoringLateCallbacks() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringSpeechProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.prepareLocalSpeechModel()
    await provider.waitUntilStarted()
    await provider.emitProgress(completed: 1, total: 2)
    await waitUntil {
      harness.model.voice.localSpeechPreparationProgress == 0.5
    }

    harness.model.voice.cancelLocalSpeechModelPreparation()
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.voice.localSpeechPreparedModelIdentifier)
    await provider.waitUntilCancellationObserved()

    await provider.emitProgress(completed: 1, total: 1)
    await provider.release(returning: "cancelled-late-model")
    await waitForEventProcessing(harness)
    await harness.model.flushPendingPersistenceWrites()

    let settings = await settingsStore.activitySnapshot()
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.voice.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.voice.downloadedLocalSpeechModels.isEmpty)
    XCTAssertNil(settings.storage[.localSpeechDownloadedModels])
    XCTAssertFalse(
      harness.model.history.eventFeed.contains { $0.english.contains("cancelled-late-model") }
    )
    XCTAssertEqual(harness.model.voice.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
    await harness.model.drainAndStopEventListenerForApplicationShutdown()
  }

  func testSettingsResetRetiresOldTaskAndItsCompletionCannotClearReplacement() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let firstProvider = CancellationIgnoringSpeechProvider()
    let secondProvider = CancellationIgnoringSpeechProvider()
    let providerQueue = CancellationIgnoringSpeechProviderQueue([
      firstProvider,
      secondProvider,
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await providerQueue.prepare(progressCallback: progressCallback)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.prepareLocalSpeechModel()
    await firstProvider.waitUntilStarted()
    harness.model.applyLocalSpeechPrewarm(true)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    harness.model.prepareLocalSpeechModel()
    await secondProvider.waitUntilStarted()

    await firstProvider.release(returning: "retired-model")
    await waitForEventProcessing(harness)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .preparing)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.voice.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.voice.downloadedLocalSpeechModels.isEmpty)

    await secondProvider.emitProgress(completed: 3, total: 4)
    await waitUntil {
      harness.model.voice.localSpeechPreparationProgress == 0.75
    }
    await secondProvider.release(returning: "qwen3-asr-0.6b-mlx-8bit")
    await waitUntil {
      harness.model.voice.localSpeechPreparationState == .ready
    }

    XCTAssertEqual(harness.model.voice.localSpeechPreparedModelIdentifier, "qwen3-asr-0.6b-mlx-8bit")
    XCTAssertEqual(harness.model.voice.downloadedLocalSpeechModels, ["qwen3-asr-0.6b-mlx-8bit"])
    XCTAssertFalse(
      harness.model.history.eventFeed.contains { $0.english.contains("retired-model") }
    )
    XCTAssertEqual(harness.model.voice.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
    await harness.model.drainAndStopEventListenerForApplicationShutdown()
  }

  func testShutdownDoesNotWaitForRetiredOrActiveCancellationIgnoringPreparations() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let retiredProvider = CancellationIgnoringSpeechProvider()
    let activeProvider = CancellationIgnoringSpeechProvider()
    let providerQueue = CancellationIgnoringSpeechProviderQueue([
      retiredProvider,
      activeProvider,
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await providerQueue.prepare(progressCallback: progressCallback)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.prepareLocalSpeechModel()
    await retiredProvider.waitUntilStarted()
    harness.model.voice.cancelLocalSpeechModelPreparation()
    harness.model.prepareLocalSpeechModel()
    await activeProvider.waitUntilStarted()

    let completion = SpeechShutdownCompletionProbe()
    let shutdownTask = Task {
      await harness.model.stopLocalSpeechPreparationForApplicationShutdown()
      await completion.markCompleted()
    }
    await retiredProvider.waitUntilCancellationObserved()
    await activeProvider.waitUntilCancellationObserved()

    await waitUntilAsync {
      await completion.isCompleted()
    }
    XCTAssertEqual(harness.model.voice.localSpeechPreparationTaskOwner.state, .stopped)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationTaskOwner.trackedTaskCount, 0)

    await activeProvider.release(returning: "active-late-model")
    await retiredProvider.release(returning: "retired-late-model")
    await shutdownTask.value
    await waitForEventProcessing(harness)

    let didComplete = await completion.isCompleted()
    XCTAssertTrue(didComplete)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertTrue(harness.model.voice.downloadedLocalSpeechModels.isEmpty)
  }

  func testShutdownReleasesCancellationIgnoringManualPreparationAndRejectsLateCallbacks() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringSpeechProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.prepareLocalSpeechModel()
    await provider.waitUntilStarted()
    await provider.emitProgress(completed: 1, total: 2)
    await waitUntil {
      harness.model.voice.localSpeechPreparationProgress == 0.5
    }

    let completion = SpeechShutdownCompletionProbe()
    let shutdownTask = Task {
      await harness.model.stopLocalSpeechPreparationForApplicationShutdown()
      await harness.model.flushPendingPersistenceWrites()
      await completion.markCompleted()
    }
    await provider.waitUntilCancellationObserved()
    await waitUntilAsync {
      await completion.isCompleted()
    }

    await provider.emitProgress(completed: 3, total: 4)
    await provider.release(returning: "late-manual-model")
    await shutdownTask.value
    for _ in 0..<10 {
      await Task.yield()
    }

    let settings = await settingsStore.activitySnapshot()
    XCTAssertEqual(harness.model.voice.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.voice.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.voice.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.voice.downloadedLocalSpeechModels.isEmpty)
    XCTAssertNil(settings.storage[.localSpeechDownloadedModels])
    XCTAssertNil(settings.setCounts[.localSpeechDownloadedModels])
    XCTAssertFalse(
      harness.model.history.eventFeed.contains { $0.english.contains("late-manual-model") }
    )
    await harness.model.drainAndStopEventListenerForApplicationShutdown()
  }

  private func waitUntil(
    attempts: Int = 200,
    _ predicate: () -> Bool
  ) async {
    for _ in 0..<attempts {
      if predicate() {
        return
      }
      await Task.yield()
    }
    XCTFail("The asynchronous condition did not become true.")
  }

  private func waitUntilAsync(
    attempts: Int = 200,
    _ predicate: () async -> Bool
  ) async {
    for _ in 0..<attempts {
      if await predicate() {
        return
      }
      await Task.yield()
    }
    XCTFail("The asynchronous condition did not become true.")
  }
}
