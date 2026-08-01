import XCTest

@testable import RillApp

private actor StartupOperationGate {
  private var hasEntered = false
  private var isReleased = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    hasEntered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor StartupLifecycleProbe {
  struct Snapshot: Sendable, Equatable {
    let startupCancellationObserved: Bool
    let startupFinished: Bool
    let producerStopCount: Int
    let shutdownFinished: Bool
  }

  private var startupCancellationObserved = false
  private var startupFinished = false
  private var producerStopCount = 0
  private var shutdownFinished = false
  private var startupCancellationWaiters: [CheckedContinuation<Void, Never>] = []

  func recordStartupCancellation() {
    startupCancellationObserved = true
    let waiters = startupCancellationWaiters
    startupCancellationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilStartupCancellationObserved() async {
    guard !startupCancellationObserved else { return }
    await withCheckedContinuation { continuation in
      startupCancellationWaiters.append(continuation)
    }
  }

  func recordStartupFinished() {
    startupFinished = true
  }

  func recordProducerStop() {
    producerStopCount += 1
  }

  func recordShutdownFinished() {
    shutdownFinished = true
  }

  func snapshot() -> Snapshot {
    Snapshot(
      startupCancellationObserved: startupCancellationObserved,
      startupFinished: startupFinished,
      producerStopCount: producerStopCount,
      shutdownFinished: shutdownFinished
    )
  }
}

private actor GlobalInputStartupOrderProbe {
  private var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private actor GlobalInputReadinessGate {
  private var hasEntered = false
  private var isReleased = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    hasEntered = true
    let waiters = entryWaiters
    entryWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { continuation in
      entryWaiters.append(continuation)
    }
  }

  func release() {
    isReleased = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

final class ApplicationStartupTaskCoordinatorTests: XCTestCase {
  func testGlobalInputWaitsForVoiceConfigurationBeforeStartingSharedProducerFailClosed() async {
    let probe = GlobalInputStartupOrderProbe()
    let readinessGate = GlobalInputReadinessGate()

    let startupTask = Task {
      await GlobalInputStartupSequence.run(
        startRecordingConsumer: {
          await probe.append("recording-consumer")
        },
        waitForVoiceConfiguration: {
          await probe.append("voice-configuration.waiting")
          await readinessGate.wait()
          await probe.append("voice-configuration.ready")
        },
        startClipboardConsumer: { isEnabled in
          await probe.append("clipboard-consumer:\(isEnabled)")
        },
        startSharedInputProducer: {
          await probe.append("shared-producer")
        }
      )
    }

    await readinessGate.waitUntilEntered()
    let blockedEvents = await probe.snapshot()
    XCTAssertEqual(
      blockedEvents,
      ["recording-consumer", "voice-configuration.waiting"],
      "The event tap must remain unavailable while durable voice settings are unresolved."
    )

    await readinessGate.release()
    await startupTask.value

    let events = await probe.snapshot()
    XCTAssertEqual(
      events,
      [
        "recording-consumer",
        "voice-configuration.waiting",
        "voice-configuration.ready",
        "clipboard-consumer:false",
        "shared-producer",
      ]
    )
  }

  func testApplicationShutdownCancelsAndDrainsStartupCoordinatorBeforeStoppingProducers() async {
    let startupGate = StartupOperationGate()
    let probe = StartupLifecycleProbe()
    let coordinator = ApplicationStartupTaskCoordinator(
      operations: [
        {
          await withTaskCancellationHandler {
            await startupGate.wait()
          } onCancel: {
            Task {
              await probe.recordStartupCancellation()
            }
          }
          await probe.recordStartupFinished()
        }
      ]
    )
    await startupGate.waitUntilEntered()

    let shutdown = ApplicationShutdownOperation.make(
      stopStartupTasks: {
        await AppBootstrap.stopStartupTasks(coordinator: coordinator)
      },
      cancelRecording: {
        await probe.recordProducerStop()
      },
      cancelWorkflowRun: {},
      cancelFailedAudioRecoveryRetries: {},
      stopLocalHistoryMaintenance: {},
      shutdownAudioQueue: {},
      stopStackPaste: {},
      stopClipboardGroupScheduler: {},
      stopLocalSpeechPreparation: {},
      stopEventListener: {},
      flushPersistence: {}
    )
    let shutdownTask = Task {
      await shutdown()
      await probe.recordShutdownFinished()
    }

    await probe.waitUntilStartupCancellationObserved()
    let blockedSnapshot = await probe.snapshot()
    XCTAssertTrue(blockedSnapshot.startupCancellationObserved)
    XCTAssertFalse(blockedSnapshot.startupFinished)
    XCTAssertEqual(blockedSnapshot.producerStopCount, 0)
    XCTAssertFalse(blockedSnapshot.shutdownFinished)

    await startupGate.release()
    await shutdownTask.value

    let completedSnapshot = await probe.snapshot()
    XCTAssertTrue(completedSnapshot.startupFinished)
    XCTAssertEqual(completedSnapshot.producerStopCount, 1)
    XCTAssertTrue(completedSnapshot.shutdownFinished)
  }
}
