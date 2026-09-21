import Foundation
import RillCore

/// An ordered delivery stream for consumers that must establish a shutdown
/// barrier after event producers have stopped.
public enum EventBusDelivery: Sendable, Equatable {
  case event(RillEvent)
  case barrier(UUID)
}

private enum EventBusStateProjectionKey: Sendable, Equatable {
  case liveSubtitle(UUID)
  case audioProcessingQueue
  case failedAudioRecovery
}

private enum EventBusCoalescingDisposition: Sendable {
  case replaceableState(EventBusStateProjectionKey)
  case diagnostic
  case boundary
}

private final class EventBusBufferedChannel<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let coalescingDisposition:
    @Sendable (_ incoming: Element) -> EventBusCoalescingDisposition
  private let capacity: Int
  private let diagnosticCapacity: Int
  private var pending: [(Element, EventBusAdmission)] = []
  private var bufferedElements: [Element] = []
  private var bufferedHeadIndex = 0
  private var replaceableStateIndex: Int?
  private var replaceableStateKey: EventBusStateProjectionKey?
  private var waiter: CheckedContinuation<Element?, Never>?
  private var isFinished = false

  init(
    capacity: Int, diagnosticCapacity: Int,
    coalescingDisposition:
      @escaping @Sendable (_ incoming: Element) -> EventBusCoalescingDisposition
  ) {
    self.capacity = capacity
    self.diagnosticCapacity = diagnosticCapacity
    self.coalescingDisposition = coalescingDisposition
  }

  var pendingCount: Int { lock.withLock { pending.count } }

  func send(_ element: Element) -> EventBusAdmission? {
    var admission: EventBusAdmission?
    let waitingConsumer = lock.withLock { () -> CheckedContinuation<Element?, Never>? in
      guard !isFinished else { return nil }
      if let waiter {
        self.waiter = nil
        return waiter
      }

      let disposition = coalescingDisposition(element)
      if case .diagnostic = disposition {
        // Keep the buffered head while reliable publishers wait for admission.
        guard pending.isEmpty else { return nil }
        let indices = (bufferedHeadIndex..<bufferedElements.count).filter {
          if case .diagnostic = coalescingDisposition(bufferedElements[$0]) { return true }
          return false
        }
        if indices.count >= diagnosticCapacity, let oldest = indices.first {
          bufferedElements.remove(at: oldest)
          if let index = replaceableStateIndex, index > oldest { replaceableStateIndex = index - 1 }
        }
      }
      if !pending.isEmpty || bufferedElements.count - bufferedHeadIndex >= capacity {
        switch disposition {
        case .diagnostic: return nil
        case .replaceableState(let key):
          if let index = replaceableStateIndex, replaceableStateKey == key {
            bufferedElements[index] = element
            return nil
          }
        case .boundary: break
        }
        let ticket = EventBusAdmission { [weak self] id in self?.cancelAdmission(id) }
        pending.append((element, ticket))
        admission = ticket
        replaceableStateIndex = nil
        replaceableStateKey = nil
        return nil
      }
      switch disposition {
      case .replaceableState(let key):
        if let replaceableStateIndex, replaceableStateKey == key {
          bufferedElements[replaceableStateIndex] = element
        } else {
          bufferedElements.append(element)
          replaceableStateIndex = bufferedElements.index(before: bufferedElements.endIndex)
          replaceableStateKey = key
        }
      case .diagnostic:
        bufferedElements.append(element)
        replaceableStateIndex = nil
        replaceableStateKey = nil
      case .boundary:
        bufferedElements.append(element)
        replaceableStateIndex = nil
        replaceableStateKey = nil
      }
      return nil
    }
    waitingConsumer?.resume(returning: element)
    return admission
  }

  private func cancelAdmission(_ id: UUID) {
    let admission = lock.withLock { () -> EventBusAdmission? in
      guard let index = pending.firstIndex(where: { $0.1.id == id }) else { return nil }
      return pending.remove(at: index).1
    }
    admission?.resume()
  }

  func next() async -> Element? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        var immediateResult: Element??
        lock.withLock {
          if bufferedHeadIndex < bufferedElements.endIndex {
            immediateResult = .some(bufferedElements[bufferedHeadIndex])
            if replaceableStateIndex == bufferedHeadIndex {
              replaceableStateIndex = nil
              replaceableStateKey = nil
            }
            bufferedHeadIndex += 1
            compactConsumedPrefixIfNeeded()
            if !pending.isEmpty {
              let (element, admission) = pending.removeFirst()
              bufferedElements.append(element)
              replaceableStateIndex = nil
              replaceableStateKey = nil
              admission.resume()
            }
          } else if isFinished || Task.isCancelled {
            immediateResult = .some(nil)
          } else {
            precondition(waiter == nil, "An event stream supports one consumer.")
            waiter = continuation
          }
        }
        if let immediateResult {
          continuation.resume(returning: immediateResult)
        }
      }
    } onCancel: {
      self.finish()
    }
  }

  func finish() {
    let waitingConsumer = lock.withLock { () -> CheckedContinuation<Element?, Never>? in
      guard !isFinished else { return nil }
      isFinished = true
      for (_, admission) in pending { admission.resume() }
      pending.removeAll()
      bufferedElements.removeAll(keepingCapacity: false)
      bufferedHeadIndex = 0
      replaceableStateIndex = nil
      replaceableStateKey = nil
      let waiter = waiter
      self.waiter = nil
      return waiter
    }
    waitingConsumer?.resume(returning: nil)
  }

  /// Keeps dequeue amortized O(1) without retaining an indefinitely growing
  /// consumed prefix. Compaction occurs only after a substantial prefix has
  /// accumulated and that prefix occupies at least half of the allocation.
  private func compactConsumedPrefixIfNeeded() {
    guard bufferedHeadIndex > 0 else { return }
    if bufferedHeadIndex == bufferedElements.endIndex {
      bufferedElements.removeAll(keepingCapacity: true)
      bufferedHeadIndex = 0
      replaceableStateIndex = nil
      replaceableStateKey = nil
      return
    }

    let minimumCompactionCount = 256
    guard
      bufferedHeadIndex >= minimumCompactionCount,
      bufferedHeadIndex >= bufferedElements.count - bufferedHeadIndex
    else { return }

    let consumedCount = bufferedHeadIndex
    bufferedElements.removeFirst(consumedCount)
    bufferedHeadIndex = 0
    if let replaceableStateIndex {
      self.replaceableStateIndex = replaceableStateIndex - consumedCount
    }
  }
}

extension RillEvent {
  fileprivate var retainsDeliveryAfterCancellation: Bool {
    switch self {
    case .runCompleted, .runCancelled, .runFailed, .runReceiptRepositoryChanged, .runHistoryUpdated,
      .audioProcessingQueueUpdated, .failedAudioRecoveryUpdated:
      true
    case .liveSubtitleUpdated(let snapshot): !snapshot.isVisible
    default: false
    }
  }

  fileprivate var eventBusCoalescingDisposition: EventBusCoalescingDisposition {
    if case .diagnostic = self { return .diagnostic }
    if case .liveSubtitleUpdated(let snapshot) = self, !snapshot.isVisible {
      // A terminal hidden snapshot closes one visible-presentation segment.
      // Treat it as a boundary so a stalled consumer observes the newest
      // visible snapshot before the run disappears instead of seeing only the
      // coalesced terminal state.
      return .boundary
    }
    if let key = stateProjectionKey {
      return .replaceableState(key)
    }
    return .boundary
  }

  fileprivate var stateProjectionKey: EventBusStateProjectionKey? {
    switch self {
    case .liveSubtitleUpdated(let snapshot):
      return .liveSubtitle(snapshot.runID)
    case .audioProcessingQueueUpdated:
      return .audioProcessingQueue
    case .failedAudioRecoveryUpdated:
      return .failedAudioRecovery
    default:
      return nil
    }
  }

}

extension EventBusDelivery {
  fileprivate var eventBusCoalescingDisposition: EventBusCoalescingDisposition {
    guard case .event(let event) = self else { return .boundary }
    return event.eventBusCoalescingDisposition
  }
}

public actor EventBus {
  private var eventDeliveryChannels: [UUID: EventBusBufferedChannel<RillEvent>] = [:]
  /// Reserved synchronously during EventBus initialization so the single UI
  /// lifecycle consumer cannot miss events before its Task begins iterating.
  /// This stream is intentionally single-consumer.
  public nonisolated let lifecycleDeliveryStream: AsyncStream<EventBusDelivery>
  private let lifecycleDeliveryChannel: EventBusBufferedChannel<EventBusDelivery>

  private let capacity: Int
  private let diagnosticCapacity: Int

  public init(maxBufferedEvents: Int = 4096, maxBufferedDiagnostics: Int = 256) {
    precondition(maxBufferedEvents > 0 && maxBufferedDiagnostics > 0)
    capacity = maxBufferedEvents
    diagnosticCapacity = min(maxBufferedDiagnostics, maxBufferedEvents)
    let channel = EventBusBufferedChannel<EventBusDelivery>(
      capacity: maxBufferedEvents,
      diagnosticCapacity: min(maxBufferedDiagnostics, maxBufferedEvents)
    ) { incoming in
      incoming.eventBusCoalescingDisposition
    }
    lifecycleDeliveryChannel = channel
    lifecycleDeliveryStream = AsyncStream(
      unfolding: { await channel.next() },
      onCancel: { channel.finish() }
    )
  }

  /// State projections coalesce within a segment; diagnostics retain a bounded
  /// recent tail. Other events apply backpressure and preserve FIFO order.
  /// Cancelling a blocked publisher withdraws only unadmitted progress events.
  /// Terminals, durable invalidations, and final state remain owned until admitted.
  public func stream() -> AsyncStream<RillEvent> {
    let id = UUID()
    let channel = EventBusBufferedChannel<RillEvent>(
      capacity: capacity, diagnosticCapacity: diagnosticCapacity
    ) { incoming in
      incoming.eventBusCoalescingDisposition
    }
    eventDeliveryChannels[id] = channel
    return AsyncStream(
      unfolding: { await channel.next() },
      onCancel: { Task { await self.removeEventDeliveryChannel(id) } }
    )
  }

  var pendingLifecycleEventCount: Int { lifecycleDeliveryChannel.pendingCount }

  public func publish(_ event: RillEvent) async {
    let admissions = enqueue(event)
    if event.retainsDeliveryAfterCancellation {
      // The caller joins this task: shutdown keeps consumers alive until every
      // producer has delivered its terminal state, even if its run was cancelled.
      await Task {
        for admission in admissions { await admission.wait() }
      }.value
    } else {
      for admission in admissions { await admission.wait() }
    }
  }

  private func enqueue(_ event: RillEvent) -> [EventBusAdmission] {
    var admissions: [EventBusAdmission] = []
    for channel in eventDeliveryChannels.values {
      if let admission = channel.send(event) { admissions.append(admission) }
    }
    if let admission = lifecycleDeliveryChannel.send(.event(event)) { admissions.append(admission) }
    return admissions
  }

  /// Inserts an ordered marker only into delivery streams. Ordinary event
  /// subscribers never observe lifecycle coordination traffic.
  public func publishBarrier(_ id: UUID) async {
    if let admission = lifecycleDeliveryChannel.send(.barrier(id)) { await admission.wait() }
  }

  private func removeEventDeliveryChannel(_ id: UUID) {
    guard let channel = eventDeliveryChannels.removeValue(forKey: id) else { return }
    channel.finish()
  }
}

private final class EventBusAdmission: @unchecked Sendable {
  private let lock = NSLock()
  let id = UUID()
  private let cancelPending: @Sendable (UUID) -> Void
  private var admitted = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(cancelPending: @escaping @Sendable (UUID) -> Void) {
    self.cancelPending = cancelPending
  }

  func wait() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let ready = lock.withLock {
          if admitted { return true }
          self.continuation = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      self.cancelPending(self.id)
    }
  }
  func resume() {
    let waiting = lock.withLock {
      admitted = true
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume()
  }
}
