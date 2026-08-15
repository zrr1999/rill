import XCTest

@testable import RillCore
@testable import RillRuntime

final class EventBusTests: XCTestCase {
  func testDeliveryBarrierPreservesOrderingWithoutLeakingIntoEventStream() async {
    let eventBus = EventBus()
    let eventStream = await eventBus.stream()
    let deliveryStream = eventBus.lifecycleDeliveryStream
    var eventIterator = eventStream.makeAsyncIterator()
    var deliveryIterator = deliveryStream.makeAsyncIterator()
    let first = RillEvent.runFailed(
      runID: nil,
      workflow: nil,
      message: "first"
    )
    let second = RillEvent.runFailed(
      runID: nil,
      workflow: nil,
      message: "second"
    )
    let barrierID = UUID()

    await eventBus.publish(first)
    await eventBus.publishBarrier(barrierID)
    await eventBus.publish(second)

    let firstEvent = await eventIterator.next()
    let secondEvent = await eventIterator.next()
    let firstDelivery = await deliveryIterator.next()
    let barrierDelivery = await deliveryIterator.next()
    let secondDelivery = await deliveryIterator.next()

    XCTAssertEqual(firstEvent, first)
    XCTAssertEqual(secondEvent, second)
    XCTAssertEqual(firstDelivery, .event(first))
    XCTAssertEqual(barrierDelivery, .barrier(barrierID))
    XCTAssertEqual(secondDelivery, .event(second))
  }





  func testOrdinaryStreamCoalescesEveryHighFrequencyStateProjectionByType() async {
    let eventBus = EventBus()
    let stream = await eventBus.stream()
    var iterator = stream.makeAsyncIterator()
    let runID = UUID()
    let firstLiveSubtitle = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "first"
    )
    let newestLiveSubtitle = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "newest"
    )
    let firstAudioQueue = AudioProcessingQueueSnapshot(pendingCount: 1)
    let newestAudioQueue = AudioProcessingQueueSnapshot(pendingCount: 4)
    let recoveryReceipt = makeFailedAudioRecoveryReceipt()

    await eventBus.publish(.liveSubtitleUpdated(firstLiveSubtitle))
    await eventBus.publish(.liveSubtitleUpdated(newestLiveSubtitle))
    await eventBus.publish(.audioProcessingQueueUpdated(firstAudioQueue))
    await eventBus.publish(.audioProcessingQueueUpdated(newestAudioQueue))
    await eventBus.publish(.failedAudioRecoveryUpdated([recoveryReceipt]))
    await eventBus.publish(.failedAudioRecoveryUpdated([]))

    let deliveredLiveSubtitle = await iterator.next()
    let deliveredAudioQueue = await iterator.next()
    let deliveredRecoveries = await iterator.next()

    XCTAssertEqual(deliveredLiveSubtitle, .liveSubtitleUpdated(newestLiveSubtitle))
    XCTAssertEqual(deliveredAudioQueue, .audioProcessingQueueUpdated(newestAudioQueue))
    XCTAssertEqual(deliveredRecoveries, .failedAudioRecoveryUpdated([]))
  }

  func testTerminalHiddenPreservesLatestVisibleSubtitleForStalledConsumers() async {
    let eventBus = EventBus()
    let stream = await eventBus.stream()
    var eventIterator = stream.makeAsyncIterator()
    var lifecycleIterator = eventBus.lifecycleDeliveryStream.makeAsyncIterator()
    let preparingOnlyRunID = UUID()
    let activeRunID = UUID()
    let preparingOnly = LiveSubtitleSnapshot(
      runID: preparingOnlyRunID,
      phase: .preparing
    )
    let preparing = LiveSubtitleSnapshot(runID: activeRunID, phase: .preparing)
    let latestVisible = LiveSubtitleSnapshot(
      runID: activeRunID,
      phase: .recording,
      levelMeter: [0.25, 0.75]
    )
    let preparingOnlyHidden = LiveSubtitleSnapshot(
      runID: preparingOnlyRunID,
      phase: .hidden
    )
    let activeHidden = LiveSubtitleSnapshot(runID: activeRunID, phase: .hidden)

    // Publish both runs before either iterator advances. The consumers are
    // intentionally stalled while the visible and terminal states arrive.
    await eventBus.publish(.liveSubtitleUpdated(preparingOnly))
    await eventBus.publish(.liveSubtitleUpdated(preparingOnlyHidden))
    await eventBus.publish(.liveSubtitleUpdated(preparing))
    await eventBus.publish(.liveSubtitleUpdated(latestVisible))
    await eventBus.publish(.liveSubtitleUpdated(activeHidden))

    let expectedEvents: [RillEvent] = [
      .liveSubtitleUpdated(preparingOnly),
      .liveSubtitleUpdated(preparingOnlyHidden),
      .liveSubtitleUpdated(latestVisible),
      .liveSubtitleUpdated(activeHidden),
    ]
    for expected in expectedEvents {
      let deliveredEvent = await eventIterator.next()
      let deliveredLifecycleEvent = await lifecycleIterator.next()
      XCTAssertEqual(deliveredEvent, expected)
      XCTAssertEqual(deliveredLifecycleEvent, .event(expected))
    }
  }

  func testNonClipboardStateProjectionDoesNotCoalesceAcrossDiagnosticEvent() async {
    let eventBus = EventBus()
    let stream = await eventBus.stream()
    var iterator = stream.makeAsyncIterator()
    let runID = UUID()
    let first = RillEvent.liveSubtitleUpdated(
      LiveSubtitleSnapshot(runID: runID, phase: .transcribing, hypothesisText: "first")
    )
    let diagnostic = RillEvent.diagnostic(
      DiagnosticEvent(
        subsystem: .systemClipboard,
        level: .debug,
        event: "clipboard.snapshot",
        message: "Clipboard store updated."
      )
    )
    let second = RillEvent.liveSubtitleUpdated(
      LiveSubtitleSnapshot(runID: runID, phase: .transcribing, hypothesisText: "second")
    )

    await eventBus.publish(first)
    await eventBus.publish(diagnostic)
    await eventBus.publish(second)

    let deliveredFirst = await iterator.next()
    let deliveredDiagnostic = await iterator.next()
    let deliveredSecond = await iterator.next()

    XCTAssertEqual(deliveredFirst, first)
    XCTAssertEqual(deliveredDiagnostic, diagnostic)
    XCTAssertEqual(deliveredSecond, second)
  }

  func testLiveSubtitleCoalescingDoesNotCrossRunIdentity() async {
    let eventBus = EventBus()
    let stream = await eventBus.stream()
    var iterator = stream.makeAsyncIterator()
    let first = RillEvent.liveSubtitleUpdated(
      LiveSubtitleSnapshot(runID: UUID(), phase: .transcribing, hypothesisText: "first run")
    )
    let second = RillEvent.liveSubtitleUpdated(
      LiveSubtitleSnapshot(runID: UUID(), phase: .transcribing, hypothesisText: "second run")
    )

    await eventBus.publish(first)
    await eventBus.publish(second)

    let deliveredFirst = await iterator.next()
    let deliveredSecond = await iterator.next()

    XCTAssertEqual(deliveredFirst, first)
    XCTAssertEqual(deliveredSecond, second)
  }

  func testLifecycleBarrierSeparatesLiveSubtitleCoalescingSegments() async {
    let eventBus = EventBus()
    var iterator = eventBus.lifecycleDeliveryStream.makeAsyncIterator()
    let runID = UUID()
    let barrierID = UUID()
    let beforeBarrier = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "before"
    )
    let newestBeforeBarrier = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "newest before"
    )
    let afterBarrier = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "after"
    )
    let newestAfterBarrier = LiveSubtitleSnapshot(
      runID: runID,
      phase: .transcribing,
      hypothesisText: "newest after"
    )

    await eventBus.publish(.liveSubtitleUpdated(beforeBarrier))
    await eventBus.publish(.liveSubtitleUpdated(newestBeforeBarrier))
    await eventBus.publishBarrier(barrierID)
    await eventBus.publish(.liveSubtitleUpdated(afterBarrier))
    await eventBus.publish(.liveSubtitleUpdated(newestAfterBarrier))

    let deliveredBeforeBarrier = await iterator.next()
    let deliveredBarrier = await iterator.next()
    let deliveredAfterBarrier = await iterator.next()

    XCTAssertEqual(deliveredBeforeBarrier, .event(.liveSubtitleUpdated(newestBeforeBarrier)))
    XCTAssertEqual(deliveredBarrier, .barrier(barrierID))
    XCTAssertEqual(deliveredAfterBarrier, .event(.liveSubtitleUpdated(newestAfterBarrier)))
  }



  func testOrdinaryEventQueuePreservesFIFOAcrossConsumedPrefixCompaction() async {
    let eventBus = EventBus()
    let stream = await eventBus.stream()
    var iterator = stream.makeAsyncIterator()
    let orderedEvents = (0..<900).map { index in
      RillEvent.runFailed(
        runID: nil,
        workflow: nil,
        message: "ordered-\(index)"
      )
    }

    for event in orderedEvents.prefix(600) {
      await eventBus.publish(event)
    }
    for expected in orderedEvents.prefix(400) {
      let delivered = await iterator.next()
      XCTAssertEqual(delivered, expected)
    }
    for event in orderedEvents.dropFirst(600) {
      await eventBus.publish(event)
    }
    for expected in orderedEvents.dropFirst(400) {
      let delivered = await iterator.next()
      XCTAssertEqual(delivered, expected)
    }
  }
}

private func makeFailedAudioRecoveryReceipt() -> FailedAudioRecoveryReceipt {
  let createdAt = Date(timeIntervalSince1970: 1_000)
  return FailedAudioRecoveryReceipt(
    originalRunID: UUID(),
    workflowID: UUID(),
    createdAt: createdAt,
    expiresAt: createdAt.addingTimeInterval(60),
    durationSeconds: 1,
    format: AudioFormat(sampleRateHz: 16_000, channelCount: 1, encoding: .pcm16),
    plaintextByteCount: 32,
    failureStage: .recognizing,
    failureCode: .processing
  )
}
