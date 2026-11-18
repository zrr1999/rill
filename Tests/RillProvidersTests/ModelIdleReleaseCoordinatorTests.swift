import Foundation
import Testing

@testable import RillSpeech

@Suite(.timeLimit(.minutes(1)))
struct ModelIdleReleaseCoordinatorTests {
  @Test func nonresidentModelsWaitForTheConfiguredDelay() async throws {
    let clock = IdleReleaseTestClock()
    let releases = IdleReleaseEvents()
    let coordinator = ModelIdleReleaseCoordinator(delay: .seconds(30), sleep: clock.sleep)
    let task = try #require(
      await coordinator.scheduleRelease(modelID: "asr", resident: false) {
        await releases.append("asr")
      })
    await clock.waitForSleeps(1)
    #expect(await clock.durations == [.seconds(30)])
    #expect(await releases.values.isEmpty)

    await clock.resume(0)
    await task.value
    #expect(await releases.values == ["asr"])
  }

  @Test func activityAndResidencyCancelOnlyTheirModel() async throws {
    let clock = IdleReleaseTestClock()
    let releases = IdleReleaseEvents()
    let coordinator = ModelIdleReleaseCoordinator(delay: .seconds(30), sleep: clock.sleep)
    let active = try #require(
      await coordinator.scheduleRelease(modelID: "active", resident: false) {
        await releases.append("active")
      })
    let resident = try #require(
      await coordinator.scheduleRelease(modelID: "resident", resident: false) {
        await releases.append("resident")
      })
    let idle = try #require(
      await coordinator.scheduleRelease(modelID: "idle", resident: false) {
        await releases.append("idle")
      })
    await clock.waitForSleeps(3)
    await coordinator.markActive(modelID: "active")
    let replacement = await coordinator.scheduleRelease(modelID: "resident", resident: true) {
      await releases.append("unexpected resident release")
    }
    #expect(replacement == nil)
    await active.value
    await resident.value
    await clock.resumeAll()
    await idle.value
    #expect(await releases.values == ["idle"])
  }

  @Test func anOlderCompletionCannotRemoveItsReplacementTimer() async throws {
    let clock = IdleReleaseTestClock()
    let releaseBarrier = IdleReleaseTestClock()
    let releases = IdleReleaseEvents()
    let coordinator = ModelIdleReleaseCoordinator(delay: .seconds(30), sleep: clock.sleep)
    let old = try #require(
      await coordinator.scheduleRelease(modelID: "model", resident: false) {
        await releases.append("old")
        try? await releaseBarrier.sleep(.seconds(1))
      })
    await clock.waitForSleeps(1)
    await clock.resume(0)
    await releaseBarrier.waitForSleeps(1)

    let replacement = try #require(
      await coordinator.scheduleRelease(modelID: "model", resident: false) {
        await releases.append("replacement")
      })
    await old.value
    await clock.waitForSleeps(2)
    await coordinator.markActive(modelID: "model")
    await clock.resumeAll()
    await replacement.value
    #expect(await releases.values == ["old"])
  }

  @Test func cancellingAllStopsEveryPendingTimer() async throws {
    let clock = IdleReleaseTestClock()
    let releases = IdleReleaseEvents()
    let coordinator = ModelIdleReleaseCoordinator(delay: .seconds(30), sleep: clock.sleep)
    var tasks: [Task<Void, Never>] = []
    for model in ["asr", "tts"] {
      let task = try #require(
        await coordinator.scheduleRelease(modelID: model, resident: false) {
          await releases.append(model)
        })
      tasks.append(task)
    }
    await clock.waitForSleeps(2)
    await coordinator.cancelAll()
    for task in tasks { await task.value }
    #expect(await releases.values.isEmpty)
  }
}

private actor IdleReleaseEvents {
  var values: [String] = []

  func append(_ value: String) { values.append(value) }
}

private actor IdleReleaseTestClock {
  private(set) var durations: [Duration] = []
  private var sleepers: [Int: CheckedContinuation<Void, Error>] = [:]
  private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func sleep(_ duration: Duration) async throws {
    let index = durations.count
    durations.append(duration)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        sleepers[index] = continuation
        let ready = observers.filter { $0.count <= durations.count }
        observers.removeAll { $0.count <= durations.count }
        for observer in ready { observer.continuation.resume() }
      }
    } onCancel: {
      Task { await self.cancel(index) }
    }
  }

  func waitForSleeps(_ count: Int) async {
    guard durations.count < count else { return }
    await withCheckedContinuation { observers.append((count, $0)) }
  }

  func resume(_ index: Int) {
    sleepers.removeValue(forKey: index)?.resume()
  }

  func resumeAll() {
    let current = sleepers.values
    sleepers.removeAll()
    for sleeper in current { sleeper.resume() }
  }

  private func cancel(_ index: Int) {
    sleepers.removeValue(forKey: index)?.resume(throwing: CancellationError())
  }
}
