import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

private actor CancellationIgnoringWhisperKitProvider {
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

private actor CancellationIgnoringWhisperKitProviderQueue {
  private let providers: [CancellationIgnoringWhisperKitProvider]
  private var nextProviderIndex = 0

  init(_ providers: [CancellationIgnoringWhisperKitProvider]) {
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

private actor WhisperKitShutdownCompletionProbe {
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
  func testPersistedLocalSelectionLoadsRuntimeWhenCoreMLPrewarmIsDisabled() async {
    let modelIdentifier = "persisted-local-model"
    let settingsStore = UITestSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: modelIdentifier,
        .localSpeechPrewarm: "false",
      ]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      warmLocalSpeechForCaptureAction: { settings in
        await provider.prepare(settings: settings)
      }
    )

    await provider.waitUntilStarted()

    let requestedSettings = await provider.settingsSnapshot()
    XCTAssertEqual(requestedSettings?.model, modelIdentifier)
    XCTAssertEqual(requestedSettings?.prewarm, false)
    XCTAssertEqual(harness.model.localSpeechPreparationState, .preparing)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)

    await provider.release(returning: modelIdentifier)
    await waitUntil {
      harness.model.localSpeechPreparationState == .ready
    }

    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 1)
    XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, modelIdentifier)
  }

  func testSwitchingToCloudRetiresBackgroundReadinessAndRejectsLateCompletion() async {
    let modelIdentifier = "retired-local-model"
    let settingsStore = UITestSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: modelIdentifier,
        .localSpeechPrewarm: "false",
      ]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      warmLocalSpeechForCaptureAction: { settings in
        await provider.prepare(settings: settings)
      }
    )
    await provider.waitUntilStarted()

    harness.model.preferredSpeechEngine = .cloud

    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    await provider.waitUntilCancellationObserved()
    await provider.release(returning: modelIdentifier)
    await waitForEventProcessing()

    XCTAssertEqual(harness.model.preferredSpeechEngine, .cloud)
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertFalse(harness.model.downloadedLocalSpeechModels.contains(modelIdentifier))
  }

  func testChangingModelRetiresOldReadinessAndOnlyPublishesReplacement() async {
    let firstModel = "first-local-model"
    let secondModel = "second-local-model"
    let settingsStore = UITestSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechModel: firstModel,
        .localSpeechPrewarm: "false",
      ]
    )
    let firstProvider = CancellationIgnoringWhisperKitProvider()
    let secondProvider = CancellationIgnoringWhisperKitProvider()
    let providerQueue = CancellationIgnoringWhisperKitProviderQueue([
      firstProvider,
      secondProvider,
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      warmLocalSpeechForCaptureAction: { settings in
        await providerQueue.prepare(settings: settings)
      }
    )
    await firstProvider.waitUntilStarted()

    harness.model.localSpeechModel = secondModel
    await secondProvider.waitUntilStarted()
    let replacementSettings = await secondProvider.settingsSnapshot()
    XCTAssertEqual(replacementSettings?.model, secondModel)
    XCTAssertEqual(replacementSettings?.prewarm, false)

    await firstProvider.release(returning: firstModel)
    await waitForEventProcessing()
    XCTAssertEqual(harness.model.localSpeechPreparationState, .preparing)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertFalse(harness.model.downloadedLocalSpeechModels.contains(firstModel))

    await secondProvider.release(returning: secondModel)
    await waitUntil {
      harness.model.localSpeechPreparationState == .ready
    }

    XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, secondModel)
    XCTAssertFalse(harness.model.downloadedLocalSpeechModels.contains(firstModel))
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.contains(secondModel))
  }

  func testUserCancelBeforeScheduledPreparationDoesNotStartProvider() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await waitForEventProcessing()

    harness.model.prepareLocalSpeechModel()
    harness.model.cancelLocalSpeechModelPreparation()
    for _ in 0..<20 {
      await Task.yield()
    }

    let callCount = await provider.callCount()
    XCTAssertEqual(callCount, 0)
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
  }

  func testUserCancelReturnsToIdleAndRejectsCancellationIgnoringLateCallbacks() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await waitForEventProcessing()

    harness.model.prepareLocalSpeechModel()
    await provider.waitUntilStarted()
    await provider.emitProgress(completed: 1, total: 2)
    await waitUntil {
      harness.model.localSpeechPreparationProgress == 0.5
    }

    harness.model.cancelLocalSpeechModelPreparation()
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    await provider.waitUntilCancellationObserved()

    await provider.emitProgress(completed: 1, total: 1)
    await provider.release(returning: "cancelled-late-model")
    await waitForEventProcessing()
    await harness.model.flushPendingPersistenceWrites()

    let settings = await settingsStore.activitySnapshot()
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
    XCTAssertNil(settings.storage[.localSpeechDownloadedModels])
    XCTAssertFalse(
      harness.model.eventFeed.contains { $0.english.contains("cancelled-late-model") }
    )
    XCTAssertEqual(harness.model.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
  }

  func testSettingsResetRetiresOldTaskAndItsCompletionCannotClearReplacement() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let firstProvider = CancellationIgnoringWhisperKitProvider()
    let secondProvider = CancellationIgnoringWhisperKitProvider()
    let providerQueue = CancellationIgnoringWhisperKitProviderQueue([
      firstProvider,
      secondProvider,
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await providerQueue.prepare(progressCallback: progressCallback)
      }
    )
    await waitForEventProcessing()

    harness.model.prepareLocalSpeechModel()
    await firstProvider.waitUntilStarted()
    harness.model.legacyWhisperKitLanguage = "zh"
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    harness.model.prepareLocalSpeechModel()
    await secondProvider.waitUntilStarted()

    await firstProvider.release(returning: "retired-model")
    await waitForEventProcessing()
    XCTAssertEqual(harness.model.localSpeechPreparationState, .preparing)
    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)

    await secondProvider.emitProgress(completed: 3, total: 4)
    await waitUntil {
      harness.model.localSpeechPreparationProgress == 0.75
    }
    await secondProvider.release(returning: "replacement-model")
    await waitUntil {
      harness.model.localSpeechPreparationState == .ready
    }

    XCTAssertEqual(harness.model.localSpeechPreparedModelIdentifier, "replacement-model")
    XCTAssertEqual(harness.model.downloadedLocalSpeechModels, ["replacement-model"])
    XCTAssertFalse(
      harness.model.eventFeed.contains { $0.english.contains("retired-model") }
    )
    XCTAssertEqual(harness.model.localSpeechPreparationTaskOwner.trackedTaskCount, 0)
  }

  func testShutdownDoesNotWaitForRetiredOrActiveCancellationIgnoringPreparations() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let retiredProvider = CancellationIgnoringWhisperKitProvider()
    let activeProvider = CancellationIgnoringWhisperKitProvider()
    let providerQueue = CancellationIgnoringWhisperKitProviderQueue([
      retiredProvider,
      activeProvider,
    ])
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await providerQueue.prepare(progressCallback: progressCallback)
      }
    )
    await waitForEventProcessing()

    harness.model.prepareLocalSpeechModel()
    await retiredProvider.waitUntilStarted()
    harness.model.cancelLocalSpeechModelPreparation()
    harness.model.prepareLocalSpeechModel()
    await activeProvider.waitUntilStarted()

    let completion = WhisperKitShutdownCompletionProbe()
    let shutdownTask = Task {
      await harness.model.stopLocalSpeechPreparationForApplicationShutdown()
      await completion.markCompleted()
    }
    await retiredProvider.waitUntilCancellationObserved()
    await activeProvider.waitUntilCancellationObserved()

    await waitUntilAsync {
      await completion.isCompleted()
    }
    XCTAssertEqual(harness.model.localSpeechPreparationTaskOwner.state, .stopped)
    XCTAssertEqual(harness.model.localSpeechPreparationTaskOwner.trackedTaskCount, 0)

    await activeProvider.release(returning: "active-late-model")
    await retiredProvider.release(returning: "retired-late-model")
    await shutdownTask.value
    await waitForEventProcessing()

    let didComplete = await completion.isCompleted()
    XCTAssertTrue(didComplete)
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
  }

  func testShutdownReleasesCancellationIgnoringManualPreparationAndRejectsLateCallbacks() async {
    let settingsStore = UITestSettingsStore(
      storage: [.localSpeechPrewarm: "false"]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      prepareLocalSpeechAction: { _, progressCallback in
        await provider.prepare(progressCallback: progressCallback)
      }
    )
    await waitForEventProcessing()

    harness.model.prepareLocalSpeechModel()
    await provider.waitUntilStarted()
    await provider.emitProgress(completed: 1, total: 2)
    await waitUntil {
      harness.model.localSpeechPreparationProgress == 0.5
    }

    let completion = WhisperKitShutdownCompletionProbe()
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
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
    XCTAssertNil(settings.storage[.localSpeechDownloadedModels])
    XCTAssertNil(settings.setCounts[.localSpeechDownloadedModels])
    XCTAssertFalse(
      harness.model.eventFeed.contains { $0.english.contains("late-manual-model") }
    )
  }

  func testShutdownReleasesCancellationIgnoringBackgroundReadinessWithPrewarmDisabled() async {
    let settingsStore = UITestSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechPrewarm: "false",
      ]
    )
    let provider = CancellationIgnoringWhisperKitProvider()
    let harness = makeHarness(
      settingsStore: settingsStore,
      warmLocalSpeechForCaptureAction: { settings in
        await provider.prepare(settings: settings)
      }
    )
    await provider.waitUntilStarted()

    let completion = WhisperKitShutdownCompletionProbe()
    let shutdownTask = Task {
      await harness.model.stopLocalSpeechPreparationForApplicationShutdown()
      await harness.model.flushPendingPersistenceWrites()
      await completion.markCompleted()
    }
    await provider.waitUntilCancellationObserved()
    await waitUntilAsync {
      await completion.isCompleted()
    }

    await provider.release(returning: "late-warmup-model")
    await shutdownTask.value

    let settings = await settingsStore.activitySnapshot()
    XCTAssertEqual(harness.model.localSpeechPreparationState, .idle)
    XCTAssertEqual(harness.model.localSpeechPreparationProgress, 0)
    XCTAssertNil(harness.model.localSpeechPreparedModelIdentifier)
    XCTAssertTrue(harness.model.downloadedLocalSpeechModels.isEmpty)
    XCTAssertNil(settings.storage[.localSpeechDownloadedModels])
    XCTAssertNil(settings.setCounts[.localSpeechDownloadedModels])
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
