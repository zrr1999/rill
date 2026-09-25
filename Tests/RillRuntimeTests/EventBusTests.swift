@testable import RillWorkflows
import XCTest

@testable import RillCore

final class EventBusTests: XCTestCase {
  func testCancellingBlockedPublicationWithdrawsPendingEvent() async {
    let bus = EventBus(maxBufferedEvents: 1)
    let first = RillEvent.runFailed(runID: nil, workflow: nil, message: "first")
    let cancelled = RillEvent.recordPanelRequested
    await bus.publish(first)
    let published = expectation(description: "Cancelled publisher returns without a consumer")
    let task = Task {
      await bus.publish(cancelled)
      published.fulfill()
    }
    task.cancel()
    await fulfillment(of: [published], timeout: 2)
    var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
    let delivered = await iterator.next()
    XCTAssertEqual(delivered, .event(first))
    let sentinel = UUID()
    await bus.publishBarrier(sentinel)
    let next = await iterator.next()
    XCTAssertEqual(next, .barrier(sentinel))
  }

  func testCancelledPublishersStillDeliverTerminalAndFinalState() async {
    let events: [RillEvent] = [
      .runDiscarded(runID: UUID()),
      .runCancelled(.init(runID: UUID(), stage: .recognizing, wasPartiallyCompleted: false)),
      .runFailed(runID: UUID(), workflow: nil, message: "failed"),
      .runCompleted(
        .init(
          runID: UUID(), workflowID: UUID(), workflow: .init(fallbackName: "Done"),
          trigger: .manual, finalText: "done")),
      .audioProcessingQueueUpdated(.init(pendingCount: 0)),
      .liveSubtitleUpdated(.init(runID: UUID(), phase: .hidden)),
    ]
    for event in events {
      let bus = EventBus(maxBufferedEvents: 1)
      await bus.publish(.recordPanelRequested)
      let publication = Task { await bus.publish(event) }
      publication.cancel()
      var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
      _ = await iterator.next()
      let terminal = await iterator.next()
      await publication.value
      XCTAssertEqual(terminal, .event(event))
    }
  }

  func testSlowConsumerReceivesFinalStateThenBarrier() async {
    let bus = EventBus(maxBufferedEvents: 1)
    let first = RillEvent.runFailed(runID: nil, workflow: nil, message: "boundary")
    await bus.publish(first)
    let sentinel = UUID()
    let snapshot = AudioProcessingQueueSnapshot(pendingCount: 0)
    let publisher = Task {
      await bus.publish(.audioProcessingQueueUpdated(snapshot))
      await bus.publishBarrier(sentinel)
    }
    var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
    let boundary = await iterator.next()
    let finalState = await iterator.next()
    let barrier = await iterator.next()
    await publisher.value
    XCTAssertEqual(boundary, .event(first))
    XCTAssertEqual(finalState, .event(.audioProcessingQueueUpdated(snapshot)))
    XCTAssertEqual(barrier, .barrier(sentinel))
  }

  func testDiagnosticFloodRetainsOnlyBoundedRecentTailAndTerminal() async {
    let bus = EventBus(maxBufferedEvents: 4, maxBufferedDiagnostics: 2)
    var expected: [EventBusDelivery] = []
    for index in 0..<10 {
      let event = RillEvent.diagnostic(
        DiagnosticEvent(
          subsystem: .systemClipboard, level: .debug,
          event: "diagnostic", message: "event \(index)"))
      await bus.publish(event)
      if index >= 8 { expected.append(.event(event)) }
    }
    let barrier = UUID()
    await bus.publishBarrier(barrier)
    expected.append(.barrier(barrier))
    var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
    for value in expected {
      let actual = await iterator.next()
      XCTAssertEqual(actual, value)
    }
  }

  func testDiagnosticArrivingBehindBlockedTerminalPreservesConsumerProgress() async {
    let bus = EventBus(maxBufferedEvents: 1, maxBufferedDiagnostics: 1)
    let first = RillEvent.diagnostic(
      .init(
        subsystem: .systemClipboard, level: .debug,
        event: "first", message: "first"))
    let terminal = RillEvent.runFailed(runID: UUID(), workflow: nil, message: "terminal")
    await bus.publish(first)
    let publication = Task { await bus.publish(terminal) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await bus.pendingLifecycleEventCount == 0, ContinuousClock.now < deadline {
      await Task.yield()
    }
    let pendingCount = await bus.pendingLifecycleEventCount
    XCTAssertEqual(pendingCount, 1)
    await bus.publish(
      .diagnostic(
        .init(
          subsystem: .systemClipboard, level: .debug,
          event: "later", message: "later")))

    let delivered = expectation(description: "The consumer drains the head and pending terminal")
    let consumer = Task {
      var iterator = bus.lifecycleDeliveryStream.makeAsyncIterator()
      let head = await iterator.next()
      let last = await iterator.next()
      XCTAssertEqual(head, .event(first))
      XCTAssertEqual(last, .event(terminal))
      delivered.fulfill()
    }
    await fulfillment(of: [delivered], timeout: 2)
    consumer.cancel()
    await publication.value
  }

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
