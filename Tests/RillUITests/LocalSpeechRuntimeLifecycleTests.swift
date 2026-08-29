import Foundation
import XCTest

@testable import RillCore
@testable import RillUI

@MainActor
final class LocalSpeechRuntimeLifecycleTests: XCTestCase {

  func testExplicitMemoryReleaseKeepsLocalRouteEnabled() async {
    let probe = LocalSpeechRuntimeLifecycleProbe()
    let settingsStore = UITestSettingsStore(
      storage: [
        .preferredSpeechEngine: PreferredSpeechEngine.local.rawValue,
        .localSpeechPrewarm: "false",
      ]
    )
    let harness = makeHarness(
      settingsStore: settingsStore,
      setLocalSpeechRuntimeEnabledAction: { enabled in
        probe.recordRuntimeEnabled(enabled)
      },
      releaseLocalSpeechRuntimeAction: {
        probe.recordRelease()
      }
    )
    await waitForEventProcessing(harness)
    // The runtime enable/disable call is issued by the initial settings load
    // task; synchronizeEventListener alone does not drain it.
    await harness.model.waitForInitialVoiceConfiguration()

    harness.model.releaseLocalSpeechModelMemory()

    XCTAssertEqual(harness.model.preferredSpeechEngine, .local)
    XCTAssertEqual(probe.runtimeTransitions, [true])
    XCTAssertEqual(probe.releaseCount, 1)
  }

  func testApplicationShutdownStopsRuntimeAfterPreparationDrain() async {
    let probe = LocalSpeechRuntimeLifecycleProbe()
    let harness = makeHarness(
      stopLocalSpeechRuntimeAction: {
        probe.recordStop()
      }
    )
    await waitForEventProcessing(harness)

    await harness.model.stopLocalSpeechPreparationForApplicationShutdown()

    XCTAssertEqual(probe.stopCount, 1)
  }
}

private final class LocalSpeechRuntimeLifecycleProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRuntimeTransitions: [Bool] = []
  private var storedPreparationCount = 0
  private var storedReleaseCount = 0
  private var storedStopCount = 0

  var runtimeTransitions: [Bool] {
    lock.withLock { storedRuntimeTransitions }
  }

  var preparationCount: Int {
    lock.withLock { storedPreparationCount }
  }

  var releaseCount: Int {
    lock.withLock { storedReleaseCount }
  }

  var stopCount: Int {
    lock.withLock { storedStopCount }
  }

  func recordRuntimeEnabled(_ enabled: Bool) {
    lock.withLock { storedRuntimeTransitions.append(enabled) }
  }

  func recordPreparation(model _: String) {
    lock.withLock { storedPreparationCount += 1 }
  }

  func recordRelease() {
    lock.withLock { storedReleaseCount += 1 }
  }

  func recordStop() {
    lock.withLock { storedStopCount += 1 }
  }
}
